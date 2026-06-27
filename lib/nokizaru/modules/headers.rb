# frozen_string_literal: true

require 'uri'
require 'openssl'
require 'net/http'
require_relative '../http_client'
require_relative '../log'
require_relative '../target_intel'

module Nokizaru
  module Modules
    # Nokizaru::Modules::Headers implementation
    module Headers
      module_function

      TIMEOUT = 10
      FallbackResponse = Struct.new(:status, :headers, :body, keyword_init: true)

      # Run this module and store normalized results in the run context
      def call(target, ctx)
        result = { 'headers' => {}, 'target_profile' => {} }
        UI.module_header('Headers')

        ctx.progress&.update(:headers, stage: 'fetching')
        populate_headers_result!(target, result, ctx.options[:request_headers] || {})
        ctx.progress&.update(:headers, stage: 'complete', detail: "#{result['headers'].length} headers")
        ctx.run['modules']['headers'] = result
        Log.write('[headers] Completed')
      end

      def populate_headers_result!(target, result, request_headers)
        response = fetch(URI.parse(target), request_headers: request_headers)
        return apply_missing_headers!(target, result, request_headers) unless response

        apply_header_pairs!(response, result)
        result['target_profile'] = profile_for(target, response: response, request_headers: request_headers)
      rescue OpenSSL::SSL::SSLError => e
        handle_ssl_error(e, target, result)
      rescue StandardError => e
        handle_generic_error(e, result)
      end

      def apply_missing_headers!(target, result, request_headers = {})
        UI.line(:error, 'Failed to retrieve headers')
        result['error'] = 'Failed to retrieve headers'
        result['target_profile'] = profile_for(target, request_headers: request_headers)
      end

      def apply_header_pairs!(response, result)
        pairs = []
        Nokizaru::HTTPClient.each_response_header(response) { |key, value| pairs << [key, value] }
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

      def profile_for(target, response: nil, request_headers: {})
        Nokizaru::TargetIntel.profile(
          target,
          verify_ssl: false,
          timeout_s: TIMEOUT,
          response: response,
          request_headers: request_headers
        )
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
      def fetch(uri, request_headers: {})
        response = httpx_fetch(uri, request_headers: request_headers)
        return response if response && !Nokizaru::HTTPClient.error_response?(response)

        log_httpx_error(uri, response)
        net_http_fetch(uri, request_headers: request_headers)
      rescue StandardError => e
        Log.write("[headers] HTTP error: #{e.message}")
        nil
      end

      def httpx_fetch(uri, request_headers: {})
        client = Nokizaru::HTTPClient.for_host(
          uri.to_s,
          timeout_s: TIMEOUT,
          follow_redirects: false,
          verify_ssl: false
        )
        client.get(uri.to_s, headers: build_headers(request_headers))
      end

      def log_httpx_error(uri, response)
        return unless response && Nokizaru::HTTPClient.error_response?(response)

        Log.write("[headers] HTTPX error for #{uri}: #{response.error.class} - #{response.error.message}")
      end

      def net_http_fetch(uri, request_headers: {})
        response = net_http_response(uri, build_headers(request_headers))
        FallbackResponse.new(
          status: response.code.to_i,
          headers: response.each_header.to_h,
          body: response.body.to_s
        )
      rescue StandardError => e
        Log.write("[headers] Net::HTTP fallback error for #{uri}: #{e.class} - #{e.message}")
        nil
      end

      def net_http_response(uri, headers)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        http.write_timeout = TIMEOUT if http.respond_to?(:write_timeout=)
        http.request(Net::HTTP::Get.new(request_path(uri), headers))
      end

      def request_path(uri)
        path = uri.request_uri.to_s
        path.empty? ? '/' : path
      end

      def build_headers(request_headers = {})
        Nokizaru::HTTPClient.request_headers(base: request_headers, user_agent: 'Nokizaru')
      end

      # Print SSL errors with guidance for certificate validation failures
      def display_ssl_error(error, target)
        UI.line(:error, 'SSL Error')
        UI.line(:error, error.message.to_s)

        return unless target.start_with?('https://')

        http_url = target.sub('https://', 'http://')
        UI.row(:plus, 'Suggestion', 'Try using HTTP instead of HTTPS')
        UI.row(:plus, 'Try command', "nokizaru --target #{http_url} [options]")
      end
    end
  end
end
