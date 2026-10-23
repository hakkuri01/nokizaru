# frozen_string_literal: true

module Nokizaru
  module TargetIntel
    # HTTP request helper methods used by target profiling
    module HTTPHelpers
      module_function

      def fetch(uri, verify_ssl:, timeout_s:, request_headers: {})
        client = Nokizaru::HTTPClient.for_host(
          uri.to_s,
          timeout_s: timeout_s,
          follow_redirects: false,
          verify_ssl: verify_ssl
        )
        response = client.get(uri.to_s, headers: build_headers(request_headers))
        Nokizaru::HTTPClient.error_response?(response) ? nil : response
      rescue StandardError
        nil
      end

      def build_headers(request_headers = {})
        Nokizaru::HTTPClient.request_headers(base: request_headers, user_agent: TargetIntel::USER_AGENT)
      end
    end
  end
end
