require "uri"
require "./client"
require "../destination"
require "../target_intel"

module Nokizaru
  module Http
    DEFAULT_MAX_REDIRECTS = 5
    REDIRECT_STATUSES     = {301, 302, 303, 307, 308}

    # Registrable-domain redirects require an explicit per-request scope choice
    SAME_HOST_SCOPE = ->(left : String, right : String) { left.downcase == right.downcase }

    # Per-request knobs, grouped so the request methods stay within the parameter
    # budget. Redirects are followed by default, matching the Ruby build. TLS
    # verification is not a per-request knob: the pool decides it from the
    # operator's one choice.
    struct Options
      getter headers : ::HTTP::Headers
      getter timeout_s : Float64
      getter? follow_redirects : Bool
      getter max_redirects : Int32
      getter body : String?
      getter scope_check : Proc(String, String, Bool)?
      # Per-request read timeout; nil uses the client's default READ_TIMEOUT. A
      # slow provider (crt.sh) sets this so a single slow read is not killed by
      # the global 15s cap before its own budget is spent.
      getter read_timeout_s : Float64?

      def initialize(
        @headers : ::HTTP::Headers = ::HTTP::Headers.new,
        @timeout_s : Float64 = OPERATION_TIMEOUT,
        @follow_redirects : Bool = true,
        @max_redirects : Int32 = DEFAULT_MAX_REDIRECTS,
        @body : String? = nil,
        @scope_check : Proc(String, String, Bool)? = nil,
        @read_timeout_s : Float64? = nil,
      )
      end

      def with_headers(headers : ::HTTP::Headers) : Options
        Options.new(headers, @timeout_s, @follow_redirects, @max_redirects, @body, @scope_check, @read_timeout_s)
      end
    end

    # A per-origin pool of persistent clients. Sequential requests to the same
    # origin reuse one connection; the key is (scheme, host, port, verify), looked
    # up in O(1) through a Hash behind a Mutex. This is the transport the scan
    # context injects into modules. Operator headers are passed per request
    # rather than baked into the key, so one connection serves a host regardless
    # of per-request header variation.
    class Pool
      setter scope_check : Proc(String, String, Bool)

      # `insecure_host` is the one host whose certificate is not verified: the
      # operator's --insecure choice applies to the target they aimed at, never to
      # the third-party APIs a scan also talks to (providers, archives, RDAP),
      # whose certificates stay verified. Verification is not a per-request knob,
      # so no caller can widen it.
      def initialize(*, @scope_check : Proc(String, String, Bool) = SAME_HOST_SCOPE,
                     @insecure_host : String? = nil,
                     @destination : Proc(String, Bool)? = nil,
                     @client_factory : Proc(String, Int32, Bool, Bool, Client) = ->(host : String, port : Int32, tls : Bool, verify : Bool) { Client.new(host, port, tls, verify) })
        @clients = {} of String => Client
        @allowed = {} of String => Bool
        @mutex = Mutex.new
      end

      # A fresh pool carrying this pool's transport policy, for a worker that
      # needs its own connections (the crawler's fetch workers).
      def derive : Pool
        Pool.new(scope_check: @scope_check, insecure_host: @insecure_host,
          destination: @destination, client_factory: @client_factory)
      end

      def request(method : String, url : String, options : Options = Options.new) : Result
        result = perform_once(method, url, options)
        return result unless options.follow_redirects?

        follow(method, url, options, result)
      end

      def get(url : String, options : Options = Options.new) : Result
        request("GET", url, options)
      end

      def shutdown : Nil
        @mutex.synchronize do
          @clients.each_value(&.close)
          @clients.clear
        end
      end

      # Follows same-scope redirects up to the budget, re-requesting the resolved
      # Location. On an origin change the operator's custom headers are dropped so
      # credentials never leak to a different origin; an out-of-scope or downgraded
      # Location stops the chain and returns the 3xx response for the caller to
      # inspect. The dirrec and crawler redirect rules both route through here,
      # so the scope and credential decisions have one home (security-critical).
      private def follow(method : String, url : String, options : Options, result : Result) : Result
        current = url
        current_options = options
        hops = 0
        while hops < options.max_redirects && !result.error? && redirect?(result.status)
          location = result.headers["Location"]?
          break if location.nil? || location.empty?

          hop = next_hop(current, location, url, options.scope_check || @scope_check)
          break if hop.nil?

          current, origin_changed = hop
          current_options = current_options.with_headers(::HTTP::Headers.new) if origin_changed
          result = perform_once(method, current, current_options)
          hops += 1
        end
        result
      end

      private def next_hop(current : String, location : String, scope : String, scope_check : Proc(String, String, Bool)) : {String, Bool}?
        return nil unless valid_location?(location)

        target = TargetIntel.redirect_target(current, location, scope).next_url
        return nil unless target
        destination = URI.parse(target)
        return nil if (port = destination.port) && !(1..65535).includes?(port)
        return nil unless scope_check.call(URI.parse(scope).host || "", destination.host || "")

        {target, !TargetIntel.same_origin?(current, target)}
      rescue ArgumentError
        nil
      end

      private def valid_location?(location : String) : Bool
        escaped = 0
        location.each_byte do |byte|
          if escaped > 0
            return false unless byte.in?(48..57) || byte.in?(65..70) || byte.in?(97..102)
            escaped -= 1
          elsif byte == 37
            escaped = 2
          elsif byte <= 32 || byte == 127 || byte == 92
            return false
          end
        end
        escaped == 0
      end

      private def redirect?(status : Int32?) : Bool
        !status.nil? && REDIRECT_STATUSES.includes?(status)
      end

      private def perform_once(method : String, url : String, options : Options) : Result
        uri = URI.parse(url)
        host = uri.host
        raise ArgumentError.new("URL has no host") if host.nil? || host.empty?
        return Result.failure(ErrorKind::Other, "Refused #{host}: not a public destination") unless allowed_destination?(host)

        client = client_for(uri, verified?(uri))
        client.request(method, request_target(uri), options.headers, options.timeout_s, options.body, options.read_timeout_s)
      rescue error : ArgumentError
        Result.failure(ErrorKind::Other, error.message || "Invalid URL: #{url}")
      end

      # One resolution per host, cached for the pool's life: a candidate loop asks
      # about the same host thousands of times, so this stays O(1) per request.
      # ponytail: the check and the connect resolve separately, so a name that
      # flips between them is still reached (a DNS-rebinding window). Closing it
      # needs a transport that connects to a pinned address while keeping the name
      # for Host and SNI, which stdlib HTTP::Client cannot express; the upgrade
      # path is the hand-rolled client.
      private def allowed_destination?(host : String) : Bool
        policy = @destination
        return true if policy.nil?

        key = host.downcase
        cached = @mutex.synchronize { @allowed[key]? }
        return cached unless cached.nil?

        verdict = policy.call(key)
        @mutex.synchronize { @allowed[key] = verdict }
        verdict
      end

      # The one place TLS verification is decided: on for every request, off only
      # for the single host the operator excused with --insecure.
      private def verified?(uri : URI) : Bool
        excused = @insecure_host
        return true if excused.nil?

        (uri.host || "").downcase != excused.downcase
      end

      private def client_for(uri : URI, verify_ssl : Bool) : Client
        host = uri.host
        raise ArgumentError.new("URL has no host") if host.nil? || host.empty?

        tls = uri.scheme == "https"
        port = uri.port || (tls ? 443 : 80)
        key = "#{uri.scheme}://#{host}:#{port}:ssl=#{verify_ssl}"
        @mutex.synchronize do
          @clients[key] ||= @client_factory.call(host, port, tls, verify_ssl)
        end
      end

      private def request_target(uri : URI) : String
        target = uri.path
        target = "/" if target.empty?
        query = uri.query
        query ? "#{target}?#{query}" : target
      end
    end
  end
end
