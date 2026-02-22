# frozen_string_literal: true

module Nokizaru
  module Modules
    module ArchitectureFingerprinting
      # Wappalyzer API client helpers
      module Client
        module_function

        LOOKUP_URL = 'https://api.wappalyzer.com/v2/lookup/'

        def fetch(http, target, api_key)
          response = http.get(LOOKUP_URL, headers: { 'x-api-key' => api_key }, params: { urls: target })
          return response.body.to_s if successful_status?(response)

          log_non_success(response)
          ''
        rescue StandardError => e
          log_parse_error(e)
          ''
        end

        def successful_status?(response)
          response&.status == 200
        end

        def log_non_success(response)
          status = response&.status
          reason = response_reason(response, status)
          UI.line(:error, "Architecture Fingerprinting Status : #{status || 'ERR'}#{reason}")
          Log.write("[arch] Status = #{status.inspect}, expected 200")
        end

        def response_reason(response, status)
          reason = if response.respond_to?(:error) && response.error
                     response.error.to_s
                   else
                     "status=#{status || 'ERR'}"
                   end
          reason.empty? ? '' : " (#{reason})"
        end

        def log_parse_error(error)
          UI.line(:error, "Architecture Fingerprinting Parse Exception : #{error}")
          Log.write("[arch] Parse exception = #{error}")
        end
      end
    end
  end
end
