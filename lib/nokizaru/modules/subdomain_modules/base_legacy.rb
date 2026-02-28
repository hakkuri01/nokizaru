# frozen_string_literal: true

module Nokizaru
  module Modules
    module SubdomainModules
      # Legacy compatibility helpers kept separate for readability
      module BaseLegacy
        module_function

        def safe_status(resp)
          return resp.status if resp.respond_to?(:status)

          nil
        end

        def safe_body(resp)
          return '' unless resp

          body = extract_body(resp)
          return body unless body.empty?

          fallback_body(resp)
        rescue StandardError
          ''
        end

        def extract_body(resp)
          return '' unless resp.respond_to?(:body)

          value = resp.body
          return '' unless value

          value.to_s
        end

        def fallback_body(resp)
          return '' unless resp.respond_to?(:to_s)

          value = resp.to_s
          return '' if value.include?('HTTPX::') || value.include?('headers=>') || value.start_with?('#<')

          value
        end

        def body_snippet(resp, max: 220)
          normalized = safe_body(resp).to_s.strip.gsub(/\s+/, ' ')
          return '' if normalized.empty?

          normalized.length > max ? "#{normalized[0, max]}…" : normalized
        rescue StandardError
          ''
        end

        def failure_reason(resp)
          return '' unless resp
          return http_result_reason(resp) if http_result_response?(resp)
          return error_reason(resp) if errored_response?(resp)
          return exception_reason(resp) if exception_response?(resp)

          body_snippet(resp)
        rescue StandardError
          ''
        end

        def http_result_response?(resp)
          resp.is_a?(HttpResult)
        end

        def errored_response?(resp)
          resp.respond_to?(:error) && resp.error
        end

        def exception_response?(resp)
          resp.respond_to?(:exception) && resp.exception
        end

        def http_result_reason(resp)
          resp.error? ? resp.error_message : ''
        end

        def error_reason(resp)
          message = resp.error.to_s
          message = message.split(' {', 2).first if message.include?(' {')
          message = message.split(' (', 2).first if message.start_with?('HTTP Error:') && message.include?(' (')
          message.strip
        end

        def exception_reason(resp)
          resp.exception.to_s.strip
        end

        def print_status(vendor, resp)
          return print_http_result_status(vendor, resp) if resp.is_a?(HttpResult)

          status = status_label(resp)
          reason = failure_reason(resp)
          Base.status_error(vendor, status, reason)
        end

        def print_http_result_status(vendor, resp)
          return Base.status_info(vendor, resp.status) if resp.success?

          status = resp.status || 'ERR'
          Base.status_error(vendor, status, resp.error_message)
        end

        def status_label(resp)
          status = safe_status(resp)
          status ? status.to_s : 'ERR'
        end
      end
    end
  end
end
