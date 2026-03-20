# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # HTTP primitives shared by crawler fetch helpers
      module HttpSupport
        private

        def redirect_response?(response)
          Crawler::REDIRECT_CODES.include?(response.code.to_i)
        rescue StandardError
          false
        end

        def same_scope_redirect?(from_url, to_url)
          from = URI.parse(from_url)
          to = URI.parse(to_url)
          Nokizaru::TargetIntel.same_scope_host?(from.host, to.host)
        rescue StandardError
          false
        end

        def enable_ssl!(http)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        def build_request(uri, request_headers = {}, user_agent: Crawler::USER_AGENT)
          request = Net::HTTP::Get.new(uri)
          request['User-Agent'] = user_agent
          request['Accept'] = '*/*'
          Nokizaru::RequestHeaders.apply_to_request(request, request_headers)
        end
      end
    end
  end
end
