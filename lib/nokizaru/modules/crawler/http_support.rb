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

        def build_request(uri)
          request = Net::HTTP::Get.new(uri)
          request['User-Agent'] = Crawler::USER_AGENT
          request['Accept'] = '*/*'
          request
        end
      end
    end
  end
end
