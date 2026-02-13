# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require_relative '../log'
require_relative '../target_intel'

module Nokizaru
  module Modules
    module Headers
      module_function

      TIMEOUT = 10

      # Run this module and store normalized results in the run context
      def call(target, ctx)
        result = { 'headers' => {}, 'target_profile' => {} }
        UI.module_header('Headers :')

        begin
          uri = URI.parse(target)
          response = fetch(uri)

          if response
            pairs = response.each_header.map { |key, val| [key, val] }
            UI.rows(:info, pairs)
            pairs.each { |key, val| result['headers'][key] = val }

            result['target_profile'] = Nokizaru::TargetIntel.profile(
              target,
              verify_ssl: false,
              timeout_s: TIMEOUT,
              response: response
            )
          else
            UI.line(:error, 'Failed to retrieve headers')
            result['error'] = 'Failed to retrieve headers'
            result['target_profile'] = Nokizaru::TargetIntel.profile(target, verify_ssl: false, timeout_s: TIMEOUT)
          end
        rescue OpenSSL::SSL::SSLError => e
          display_ssl_error(e, target)
          result['error'] = e.message
          result['error_type'] = 'SSLError'
          Log.write("[headers] SSL error: #{e.message}")
        rescue StandardError => e
          UI.line(:error, "Error : #{e.class} - #{e.message}")
          result['error'] = e.message
          result['error_type'] = e.class.name
          Log.write("[headers] Exception: #{e.class} - #{e.message}")
        end

        ctx.run['modules']['headers'] = result
        Log.write('[headers] Completed')
      end

      # Read key values from env first, then keys file, and seed missing key slots
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

      # Print SSL errors with guidance for certificate validation failures
      def display_ssl_error(error, target)
        UI.line(:error, 'SSL Error')
        UI.line(:error, error.message.to_s)

        return unless target.start_with?('https://')

        http_url = target.sub('https://', 'http://')
        UI.row(:plus, 'Suggestion', 'Try using HTTP instead of HTTPS')
        UI.row(:plus, 'Try command', "nokizaru --url #{http_url} [options]")
      end
    end
  end
end
