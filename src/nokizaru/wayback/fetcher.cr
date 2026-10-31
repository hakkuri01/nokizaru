require "../http/pool"

module Nokizaru
  module Wayback
    RETRIES          =    2
    READ_TIMEOUT     = 10.0
    MIN_RETRY_BUDGET = 0.25

    # GETs the Wayback endpoints with the Ruby retry policy:
    # redirects off, and a retry only on a 429/5xx (never on a transport error,
    # matching with_retries), all attempts and backoff share one deadline. Complexity:
    # O(1) requests per call (fixed retry budget). Named Fetcher so `Http::*`
    # inside Wayback still resolves to the Nokizaru::Http module.
    class Fetcher
      @pool_factory : Proc(Http::Pool)

      # A worker's pool derives from this one by default, so every CDX fetch runs
      # under the scan's transport policy rather than a fresh unguarded pool.
      def initialize(@pool : Http::Pool,
                     *,
                     @clock : Proc(Time::Instant) = -> { Time.instant },
                     @wall_clock : Proc(Time) = -> { Time.utc },
                     @sleeper : Proc(Time::Span, Nil) = ->(delay : Time::Span) { sleep(delay) },
                     pool_factory : Proc(Http::Pool)? = nil)
        @pool_factory = pool_factory || -> { @pool.derive }
      end

      def now : Time::Instant
        @clock.call
      end

      def wait(delay : Time::Span, deadline : Time::Instant) : Nil
        remaining = deadline - now
        @sleeper.call({delay, remaining}.min) if remaining > Time::Span.zero && delay > Time::Span.zero
      end

      def worker : Fetcher
        Fetcher.new(@pool_factory.call, clock: @clock, wall_clock: @wall_clock, sleeper: @sleeper, pool_factory: @pool_factory)
      end

      def close : Nil
        @pool.shutdown
      end

      def get(url : String, deadline : Time::Instant) : Http::Result
        (RETRIES + 1).times do |attempt|
          budget = (deadline - now).total_seconds
          return timeout_result unless budget > 0

          options = Http::Options.new(timeout_s: budget, follow_redirects: false)
          result = @pool.get(url, options)
          return result unless retryable?(result) && attempt < RETRIES
          delay = retry_delay(result, attempt)
          return result if delay + MIN_RETRY_BUDGET > (deadline - now).total_seconds

          wait(delay.seconds, deadline)
        end
        timeout_result
      end

      private def timeout_result : Http::Result
        Http::Result.failure(Http::ErrorKind::Timeout, Http::TIMEOUT_MESSAGE)
      end

      private def retry_delay(result : Http::Result, attempt : Int32) : Float64
        header = result.headers["Retry-After"]?
        if header && header.bytesize <= 128
          seconds = header.to_f?
          return seconds if seconds && seconds.finite? && seconds >= 0
          if date = ::HTTP.parse_time(header)
            return {(date - @wall_clock.call).total_seconds, 0.0}.max
          end
        end
        0.25 * (2 ** attempt)
      end

      private def retryable?(result : Http::Result) : Bool
        return false if result.error?

        status = result.status
        !status.nil? && (status == 429 || (500..599).includes?(status))
      end
    end
  end
end
