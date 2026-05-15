# frozen_string_literal: true

require_relative '../../http_client'

module Nokizaru
  module Modules
    module Wayback
      # HTTP fetch helpers for Wayback endpoints
      module HTTP
        module_function

        MIN_RETRY_BUDGET = 0.25

        def get(uri, timeout_s: nil, deadline_at: nil, headers: nil)
          with_retries(uri, timeout_s: timeout_s, deadline_at: deadline_at, headers: headers)
        rescue Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, SocketError => e
          Log.write("[wayback] Timeout/network error: #{e.message}")
          nil
        rescue StandardError => e
          Log.write("[wayback] HTTP error: #{e.message}")
          nil
        end

        def with_retries(uri, timeout_s: nil, deadline_at: nil, headers: nil)
          attempts = 0
          while attempts <= Wayback::RETRIES
            attempts += 1
            budget = request_budget(timeout_s, deadline_at)
            return nil unless budget.positive?

            response = request(uri, timeout_s: budget, headers: headers)
            return response unless retryable?(response, attempts, deadline_at, timeout_s)

            sleep(retry_delay(attempts, deadline_at))
          end
          nil
        end

        def retryable?(response, attempts, deadline_at = nil, timeout_s = nil)
          retryable_status?(Nokizaru::HTTPClient.status_code(response)) &&
            attempts <= Wayback::RETRIES &&
            retry_budget?(deadline_at, timeout_s)
        end

        def request(uri, timeout_s: nil, headers: nil)
          budget = timeout_s.to_f.positive? ? timeout_s.to_f : Wayback::READ_TIMEOUT
          client = Nokizaru::HTTPClient.for_host(
            uri.to_s,
            timeout_s: budget,
            follow_redirects: false
          )
          request_headers = Nokizaru::HTTPClient.request_headers(user_agent: 'Nokizaru').merge(headers || {})
          response = client.get(uri.to_s, headers: request_headers)
          Nokizaru::HTTPClient.error_response?(response) ? nil : response
        end

        def request_budget(timeout_s, deadline_at)
          values = []
          values << timeout_s.to_f if timeout_s.to_f.positive?
          values << (deadline_at.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC)) if deadline_at
          return Wayback::READ_TIMEOUT if values.empty?

          values.min
        end

        def retry_budget?(deadline_at, timeout_s = nil)
          return true if deadline_at.nil? && timeout_s.nil?
          return timeout_s.to_f > MIN_RETRY_BUDGET unless deadline_at

          deadline_at.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC) > MIN_RETRY_BUDGET
        end

        def retry_delay(attempts, deadline_at)
          delay = 0.2 * attempts
          return delay unless deadline_at

          remaining = deadline_at.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          max_delay = [remaining - MIN_RETRY_BUDGET, 0.0].max
          delay.clamp(0.0, max_delay)
        end

        def retryable_status?(status)
          status == 429
        end
      end
    end
  end
end
