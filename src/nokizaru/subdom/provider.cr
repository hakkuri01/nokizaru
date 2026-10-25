require "uri"
require "json"
require "../http/pool"

module Nokizaru
  # Subdomain enumeration engine (Nokizaru::Subdom), distinct from the scan
  # module Nokizaru::Modules::Subdomains that drives it.
  module Subdom
    STATUS_HEALTHY      = "healthy"
    STATUS_SKIPPED      = "skipped"
    STATUS_ERROR        = "error"
    STATUS_TIMEOUT      = "timeout"
    STATUS_RATE_LIMITED = "rate_limited"

    # One provider HTTP request. Defaults to a GET with no body.
    struct Request
      getter method : String
      getter url : String
      getter headers : ::HTTP::Headers
      getter body : String?

      def initialize(@url : String, @method : String = "GET", @headers : ::HTTP::Headers = ::HTTP::Headers.new, @body : String? = nil)
      end
    end

    # The result of running one provider: its health status, the reason when not
    # healthy, how long it took, how many it returned, and the raw names (scoped
    # and deduped later by the enumerator).
    struct Outcome
      getter name : String
      getter status : String
      getter reason : String?
      getter elapsed_s : Float64?
      getter result_count : Int32?
      getter names : Array(String)

      def initialize(@name : String, @status : String, @names : Array(String), @reason : String? = nil, @elapsed_s : Float64? = nil, @result_count : Int32? = nil)
      end
    end

    # Raised when a provider's API answered with a non-success status, or an
    # application-level error (e.g. Hunter's JSON `code`). label is the status
    # token, detail the human reason.
    class ProviderError < Exception
      getter label : String
      getter detail : String?

      def initialize(@label : String, @detail : String? = nil)
        super(@detail)
      end
    end

    # Per-run state, never stored on the shared provider adapters
    class Operation
      getter names = [] of String

      def initialize(@pool : Http::Pool, @deadline : Time::Instant, @clock : Proc(Time::Instant))
      end

      def execute(request : Request) : Http::Result
        remaining = (@deadline - @clock.call).total_seconds
        raise IO::TimeoutError.new("provider execution deadline exceeded") unless remaining > 0

        # Align the per-read timeout with this provider's own budget so a slow but
        # legitimate source (crt.sh) is not cut off by the global 15s read cap
        # before its vendor budget is spent; the deadline still bounds the total.
        options = Http::Options.new(headers: request.headers, timeout_s: remaining,
          follow_redirects: false, body: request.body, read_timeout_s: remaining)
        @pool.request(request.method, request.url, options)
      end
    end

    # A subdomain source. Concrete providers supply a name, any required keys,
    # the request to make, and how to parse the response body into candidate
    # names. The base run() resolves keys (skipping when any is absent), executes
    # the request, maps the HTTP status to a health status, and times the call.
    # Paginating providers (Censys) override fetch.
    abstract class Provider
      abstract def name : String
      abstract def build(host : String, keys : Hash(String, String)) : Request
      abstract def parse(host : String, body : String) : Array(String)

      # [{keystore_name, env_var}]; empty means a public provider.
      def key_names : Array({String, String})
        [] of {String, String}
      end

      # Runs the provider with `keys` already resolved by the enumerator.
      # Complexity: O(1) requests (fetch overrides may page a bounded count),
      # plus O(body) to parse.
      def run(host : String, pool : Http::Pool, keys : Hash(String, String), timeout : Float64, *, clock : Proc(Time::Instant) = -> { Time.instant }, deadline : Time::Instant? = nil) : Outcome
        started = clock.call
        operation = Operation.new(pool, {started + timeout.seconds, deadline || started + timeout.seconds}.min, clock)
        begin
          mine = resolve_keys(keys)
          return outcome(operation, STATUS_SKIPPED, "API key not found!", (clock.call - started)) if mine.nil?

          fetch(host, operation, mine)
          outcome(operation, STATUS_HEALTHY, nil, clock.call - started)
        rescue ex : ProviderError
          outcome(operation, error_status(ex), ex.detail || ex.label, clock.call - started)
        rescue IO::TimeoutError
          outcome(operation, STATUS_TIMEOUT, "provider execution deadline exceeded", clock.call - started)
        rescue ex
          outcome(operation, STATUS_ERROR, ex.message || ex.class.name, clock.call - started)
        end
      end

      # One request then parse; paginating providers override. Statuses in
      # empty_statuses are treated as a successful empty result (AnubisDB).
      def fetch(host : String, operation : Operation, keys : Hash(String, String)) : Nil
        result = operation.execute(build(host, keys))
        return if empty_statuses.includes?(result.status)
        raise ProviderError.new(status_label(result), failure_reason(result)) unless result.status == 200

        operation.names.concat(parse(host, result.body || ""))
      end

      # Non-200 statuses that mean "no results" rather than an error.
      def empty_statuses : Array(Int32)
        [] of Int32
      end

      # Extracts the strings from a JSON array value, or [] when absent.
      protected def as_strings(value : JSON::Any?) : Array(String)
        array = value.try(&.as_a?)
        array ? array.compact_map(&.as_s?) : [] of String
      end

      protected def status_label(result : Http::Result) : String
        return STATUS_TIMEOUT if result.error_kind.timeout?
        return STATUS_RATE_LIMITED if result.status == 429

        result.status.try(&.to_s) || "ERR"
      end

      protected def failure_reason(result : Http::Result) : String?
        return result.error_message if result.error?
        return "HTTP 429" if result.status == 429

        nil
      end

      # Builds a query string onto a base URL from ordered params.
      protected def with_params(base : String, params : Array({String, String})) : String
        "#{base}?#{URI::Params.encode(params.to_h)}"
      end

      private def resolve_keys(available : Hash(String, String)) : Hash(String, String)?
        mine = {} of String => String
        key_names.each do |(keystore_name, _env)|
          value = available[keystore_name]?
          return nil if value.nil? || value.empty?

          mine[keystore_name] = value
        end
        mine
      end

      private def error_status(error : ProviderError) : String
        label = error.label.downcase
        return STATUS_RATE_LIMITED if label == STATUS_RATE_LIMITED || label == "429"

        detail = error.detail.to_s.downcase
        return STATUS_TIMEOUT if label.includes?("timeout") || detail.includes?("deadline") || detail.includes?("timeout")

        STATUS_ERROR
      end

      private def outcome(operation : Operation, status : String, reason : String?, elapsed : Time::Span) : Outcome
        names = operation.names.uniq!
        count = status == STATUS_HEALTHY || !names.empty? ? names.size : nil
        Outcome.new(name, status, names, reason, elapsed.total_seconds.round(4), count)
      end
    end
  end
end
