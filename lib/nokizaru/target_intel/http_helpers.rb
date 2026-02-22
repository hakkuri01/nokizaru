# frozen_string_literal: true

module Nokizaru
  module TargetIntel
    # HTTP request helper methods used by target profiling
    module HTTPHelpers
      module_function

      def fetch(uri, verify_ssl:, timeout_s:)
        http = build_http(uri, verify_ssl: verify_ssl, timeout_s: timeout_s)
        request = build_request(uri)
        http.request(request)
      rescue StandardError
        nil
      end

      def build_http(uri, verify_ssl:, timeout_s:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = timeout_s
        http.read_timeout = timeout_s
        return http unless uri.scheme == 'https'

        http.use_ssl = true
        http.verify_mode = verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        http
      end

      def build_request(uri)
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = TargetIntel::USER_AGENT
        request['Accept'] = '*/*'
        request
      end
    end
  end
end
