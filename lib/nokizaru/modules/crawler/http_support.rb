# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      module HttpSupport
        private

        def http_success?(response)
          Nokizaru::HTTPClient.http_success?(response)
        rescue StandardError
          false
        end

        def redirect_response?(response)
          Nokizaru::HTTPClient.http_redirect?(response, Crawler::REDIRECT_CODES)
        rescue StandardError
          false
        end

        def same_scope_redirect?(from_url, to_url)
          from = URI.parse(from_url)
          to = URI.parse(to_url)
          return false unless from.is_a?(URI::HTTP) && to.is_a?(URI::HTTP)

          Nokizaru::TargetIntel.same_scope_host?(from.host, to.host)
        rescue StandardError
          false
        end

        def build_headers(request_headers = {}, user_agent: Crawler::USER_AGENT)
          Nokizaru::HTTPClient.request_headers(base: request_headers, user_agent: user_agent)
        end
      end
    end
  end
end
