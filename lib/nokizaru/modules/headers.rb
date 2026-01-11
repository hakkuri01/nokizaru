# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require_relative '../log'

module Nokizaru
  module Modules
    module Headers
      module_function

      R = "\e[31m"
      G = "\e[32m"
      C = "\e[36m"
      W = "\e[0m"
      Y = "\e[33m"

      TIMEOUT = 10

      def call(target, ctx)
        result = { 'headers' => {} }
        puts("\n#{Y}[!] Headers :#{W}\n\n")

        begin
          uri = URI.parse(target)
          response = fetch(uri)

          if response
            response.each_header do |key, val|
              puts("#{C}#{key} : #{W}#{val}")
              result['headers'][key] = val
            end
          else
            puts("#{R}[-] #{C}Failed to retrieve headers#{W}\n")
            result['error'] = 'Failed to retrieve headers'
          end
        rescue OpenSSL::SSL::SSLError => e
          display_ssl_error(e, target)
          result['error'] = e.message
          result['error_type'] = 'SSLError'
          Log.write("[headers] SSL error: #{e.message}")
        rescue StandardError => e
          puts("#{R}[-] #{C}Error: #{W}#{e.class} - #{e.message}\n")
          result['error'] = e.message
          result['error_type'] = e.class.name
          Log.write("[headers] Exception: #{e.class} - #{e.message}")
        end

        ctx.run['modules']['headers'] = result
        Log.write('[headers] Completed')
      end

      def fetch(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Nokizaru'
        request['Accept'] = '*/*'

        http.request(request)
      rescue StandardError => e
        Log.write("[headers] HTTP error: #{e.message}")
        nil
      end

      def display_ssl_error(error, target)
        puts("#{R}[-] #{C}SSL Error#{W}")
        puts("#{R}[-] #{W}#{error.message}\n")

        return unless target.start_with?('https://')

        http_url = target.sub('https://', 'http://')
        puts("#{Y}[!] #{C}Suggestion: #{W}Try using HTTP instead of HTTPS")
        puts("#{Y}[!] #{C}Try: #{W}nokizaru --url #{http_url} [options]\n")
      end
    end
  end
end
