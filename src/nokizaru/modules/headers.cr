require "json"
require "../http/pool"
require "../target_intel"
require "../ui"

module Nokizaru
  module Modules
    # Response header collection. Fetches the target once (no redirects, TLS
    # verification off, as the Ruby tool did), records the headers and the target
    # redirect profile, and never reads the body. Field names and shape match the
    # Ruby JSON (the parity contract). Ports modules/headers.rb. The UI rendering
    # and ctx/progress wiring are assembled with the runner.
    module Headers
      extend self

      TIMEOUT = 10.0

      # A comma begins a new cookie only when a name= follows, since Expires dates
      # hold commas; the start check replaces a lookahead and stays linear-time.
      COOKIE_START = /\A\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+=/

      # A joined Set-Cookie value split back into individual cookies. Shared with
      # the posture findings.
      def split_set_cookie(value : String) : Array(String)
        cookies = [] of String
        value.split('\n').each do |line|
          line.split(',').each do |part|
            if cookies.empty? || part.matches?(COOKIE_START)
              cookies << part
            else
              cookies[-1] = "#{cookies[-1]},#{part}"
            end
          end
        end
        cookies.map(&.strip).reject(&.empty?)
      end

      struct Result
        include JSON::Serializable

        getter headers : Hash(String, String)
        getter target_profile : TargetIntel::Profile
        getter error : String?
        getter error_type : String?

        def initialize(
          @headers : Hash(String, String),
          @target_profile : TargetIntel::Profile,
          @error : String? = nil,
          @error_type : String? = nil,
        )
        end

        def self.ok(headers : Hash(String, String), profile : TargetIntel::Profile) : Result
          new(headers, profile)
        end

        def self.failure(message : String, profile : TargetIntel::Profile, error_type : String? = nil) : Result
          new({} of String => String, profile, message, error_type)
        end

        def success? : Bool
          @error.nil?
        end
      end

      # Renders the response headers for the classic output and the dashboard
      # capture: one row per header, long CSP / Set-Cookie / Vary values broken
      # into a tree. Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Headers")
        unless result.success?
          present_error(result)
          return
        end

        headers = result.headers
        width = headers.keys.max_of?(&.size) || 0
        headers.each do |key, value|
          segments = tree_segments(key, value)
          if segments.empty?
            UI.row(:info, key, value, label_width: width)
          else
            UI.tree_header(key)
            UI.tree_rows(segments)
          end
        end
      end

      private def present_error(result : Result) : Nil
        if result.error_type == "SSLError"
          UI.line(:error, "SSL Error")
          UI.line(:error, result.error || "")
        else
          UI.line(:error, result.error || "Failed to retrieve headers")
        end
      end

      # Long values gain readability as a tree; short values stay inline.
      private def tree_segments(key : String, value : String) : Array(Tuple(String, String?))
        return [] of Tuple(String, String?) if value.size <= 140

        case key.downcase
        when "content-security-policy" then split_segments(value, ';', "directive")
        when "set-cookie"              then split_set_cookie(value).map { |segment| {"cookie", segment.as(String?)} }
        when "vary"                    then split_segments(value, ',', "value")
        else                                [] of Tuple(String, String?)
        end
      end

      private def split_segments(value : String, separator : Char, label : String) : Array(Tuple(String, String?))
        value.split(separator).map(&.strip).reject(&.empty?).map { |segment| {label, segment.as(String?)} }
      end

      def collect(target : String, pool : Http::Pool, request_headers : ::HTTP::Headers = ::HTTP::Headers.new) : Result
        options = Http::Options.new(headers: request_headers, timeout_s: TIMEOUT, verify_ssl: false, follow_redirects: false)
        result = pool.get(target, options)
        if result.error?
          error_type = result.error_kind.tls? ? "SSLError" : nil
          message = result.error_message || "Failed to retrieve headers"
          return Result.failure(message, TargetIntel.profile(target, nil), error_type)
        end

        Result.ok(header_hash(result.headers), TargetIntel.profile(target, result))
      end

      # Keys are lowercased and multi-valued headers joined, as the Ruby tool
      # stored them. O(H) over the bounded header set.
      private def header_hash(headers : ::HTTP::Headers) : Hash(String, String)
        collected = {} of String => String
        headers.each { |name, values| collected[name.downcase] = values.join(", ") }
        collected
      end
    end
  end
end
