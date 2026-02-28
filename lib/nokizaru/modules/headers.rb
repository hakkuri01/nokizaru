# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require_relative '../log'
require_relative '../target_intel'

module Nokizaru
  module Modules
    # Nokizaru::Modules::Headers implementation
    module Headers
      module_function

      TIMEOUT = 10

      # Run this module and store normalized results in the run context
      def call(target, ctx)
        result = { 'headers' => {}, 'target_profile' => {} }
        UI.module_header('Headers :')

        populate_headers_result!(target, result)
        ctx.run['modules']['headers'] = result
        Log.write('[headers] Completed')
      end

      def populate_headers_result!(target, result)
        response = fetch(URI.parse(target))
        return apply_missing_headers!(target, result) unless response

        apply_header_pairs!(response, result)
        result['target_profile'] = profile_for(target, response: response)
      rescue OpenSSL::SSL::SSLError => e
        handle_ssl_error(e, target, result)
      rescue StandardError => e
        handle_generic_error(e, result)
      end

      def apply_missing_headers!(target, result)
        UI.line(:error, 'Failed to retrieve headers')
        result['error'] = 'Failed to retrieve headers'
        result['target_profile'] = profile_for(target)
      end

      def apply_header_pairs!(response, result)
        pairs = response.each_header.map { |key, value| [key, value] }
        print_header_pairs(pairs)
        pairs.each { |key, value| result['headers'][key] = value }
      end

      def print_header_pairs(pairs)
        width = Array(pairs).map { |(key, _)| key.to_s.length }.max.to_i
        Array(pairs).each do |key, value|
          segments = header_tree_segments(key, value)
          if segments.empty?
            UI.row(:info, key, value, label_width: width)
          else
            UI.tree_header(key)
            UI.tree_rows(segments)
          end
        end
      end

      def header_tree_segments(key, value)
        text = value.to_s
        return [] unless text.length > 140

        case key.to_s.downcase
        when 'content-security-policy'
          split_csp_segments(text)
        when 'set-cookie'
          split_set_cookie_segments(text)
        when 'vary'
          split_csv_segments(text)
        else
          []
        end
      end

      def split_csp_segments(value)
        value.split(';').map(&:strip).reject(&:empty?).map { |segment| ['directive', segment] }
      end

      def split_set_cookie_segments(value)
        value
          .split(/,(?=\s*[A-Za-z0-9!#$%&'*+.^_`|~-]+=)/)
          .map(&:strip)
          .reject(&:empty?)
          .map { |segment| ['cookie', segment] }
      end

      def split_csv_segments(value)
        value.split(',').map(&:strip).reject(&:empty?).map { |segment| ['value', segment] }
      end

      def profile_for(target, response: nil)
        Nokizaru::TargetIntel.profile(target, verify_ssl: false, timeout_s: TIMEOUT, response: response)
      end

      def handle_ssl_error(error, target, result)
        display_ssl_error(error, target)
        result['error'] = error.message
        result['error_type'] = 'SSLError'
        Log.write("[headers] SSL error: #{error.message}")
      end

      def handle_generic_error(error, result)
        UI.line(:error, "Error : #{error.class} - #{error.message}")
        result['error'] = error.message
        result['error_type'] = error.class.name
        Log.write("[headers] Exception: #{error.class} - #{error.message}")
      end

      # Read key values from env first, then keys file, and seed missing key slots
      def fetch(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        enable_ssl!(http) if uri.scheme == 'https'
        http.request(build_request(uri))
      rescue StandardError => e
        Log.write("[headers] HTTP error: #{e.message}")
        nil
      end

      def build_request(uri)
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Nokizaru'
        request['Accept'] = '*/*'
        request
      end

      def enable_ssl!(http)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
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
