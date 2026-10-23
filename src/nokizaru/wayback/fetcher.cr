require "../http/pool"

module Nokizaru
  module Wayback
    RETRIES      =    2
    READ_TIMEOUT = 10.0

    # GETs the Wayback endpoints over the shared pool with the Ruby retry policy:
    # redirects off, and a retry only on a 429/5xx (never on a transport error,
    # matching with_retries), backing off 0.25*2^(n-1) up to RETRIES. Complexity:
    # O(1) requests per call (fixed retry budget). Named Fetcher so `Http::*`
    # inside Wayback still resolves to the Nokizaru::Http module.
    class Fetcher
      def initialize(@pool : Http::Pool)
      end

      def get(url : String, timeout : Float64 = READ_TIMEOUT) : Http::Result
        budget = timeout > 0 ? timeout : READ_TIMEOUT
        options = Http::Options.new(timeout_s: budget, follow_redirects: false)
        result = @pool.get(url, options)
        attempt = 1
        while attempt <= RETRIES && retryable?(result)
          sleep((0.25 * (2 ** (attempt - 1))).seconds)
          result = @pool.get(url, options)
          attempt += 1
        end
        result
      end

      private def retryable?(result : Http::Result) : Bool
        return false if result.error?

        status = result.status
        !status.nil? && (status == 429 || status >= 500)
      end
    end
  end
end
