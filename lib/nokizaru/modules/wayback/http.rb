# frozen_string_literal: true

require 'net/http'

module Nokizaru
  module Modules
    module Wayback
      # HTTP fetch helpers for Wayback endpoints
      module HTTP
        module_function

        def get(uri)
          with_retries(uri)
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::EHOSTUNREACH,
               Errno::ECONNREFUSED, SocketError => e
          Log.write("[wayback] Timeout/network error: #{e.message}")
          nil
        rescue StandardError => e
          Log.write("[wayback] HTTP error: #{e.message}")
          nil
        end

        def with_retries(uri)
          attempts = 0
          while attempts <= Wayback::RETRIES
            attempts += 1
            response = request(uri)
            return response unless retryable?(response, attempts)

            sleep(0.2 * attempts)
          end
          nil
        end

        def retryable?(response, attempts)
          retryable_status?(response&.code.to_i) && attempts <= Wayback::RETRIES
        end

        def request(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = Wayback::CONNECT_TIMEOUT
          http.read_timeout = Wayback::READ_TIMEOUT
          http.use_ssl = uri.scheme == 'https'
          req = Net::HTTP::Get.new(uri)
          req['User-Agent'] = 'Nokizaru'
          http.request(req)
        end

        def retryable_status?(status)
          status == 429 || status >= 500
        end
      end
    end
  end
end
