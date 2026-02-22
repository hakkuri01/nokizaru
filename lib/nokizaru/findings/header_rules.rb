# frozen_string_literal: true

module Nokizaru
  module Findings
    # Header-focused findings rules
    module HeaderRules
      module_function

      SECURITY_HEADERS = {
        'strict-transport-security' => ['medium', 'HSTS header missing',
                                        'Enable Strict-Transport-Security if the site is HTTPS-only.'],
        'content-security-policy' => ['medium', 'CSP header missing',
                                      'Add a Content-Security-Policy to reduce XSS risk.'],
        'x-content-type-options' => ['low', 'X-Content-Type-Options header missing',
                                     'Set X-Content-Type-Options: nosniff.'],
        'x-frame-options' => ['low', 'X-Frame-Options header missing',
                              'Set X-Frame-Options to mitigate clickjacking.'],
        'referrer-policy' => ['low', 'Referrer-Policy header missing',
                              'Set Referrer-Policy to reduce referrer leakage.']
      }.freeze

      def call(headers_result)
        return [] unless headers_result.is_a?(Hash)

        headers = normalized_headers(headers_result)
        missing_header_findings(headers) + cookie_flag_findings(headers['set-cookie'])
      end

      def normalized_headers(headers_result)
        source = headers_result['headers'] || headers_result
        source.transform_keys { |key| key.to_s.downcase }
      end

      def missing_header_findings(headers)
        SECURITY_HEADERS.filter_map do |name, payload|
          build_missing_header_finding(name, payload) unless headers.key?(name)
        end
      end

      def build_missing_header_finding(header_name, payload)
        severity, title, recommendation = payload
        {
          'id' => "headers.missing_#{header_name.gsub(/[^a-z0-9]+/, '_')}",
          'severity' => severity,
          'title' => title,
          'evidence' => "Response did not include #{header_name}",
          'recommendation' => recommendation,
          'module' => 'headers',
          'tags' => %w[headers posture]
        }
      end

      def cookie_flag_findings(set_cookie)
        cookie_values(set_cookie).filter_map { |cookie| cookie_flag_finding(cookie) }
      end

      def cookie_values(set_cookie)
        return [] if set_cookie.nil?

        raw = set_cookie.is_a?(Array) ? set_cookie : set_cookie.to_s.split(/\n|,(?=\s*\w+=)/)
        raw.map(&:to_s).map(&:strip).reject(&:empty?)
      end

      def cookie_flag_finding(cookie)
        missing = missing_cookie_flags(cookie)
        return nil if missing.empty?

        cookie_finding_payload(cookie, missing)
      end

      def cookie_finding_payload(cookie, missing)
        {
          'id' => "cookies.missing_flags.#{cookie.hash}",
          'severity' => 'low',
          'title' => 'Cookie missing recommended flags',
          'evidence' => "Set-Cookie missing: #{missing.join(', ')}",
          'recommendation' => 'Add Secure, HttpOnly, and SameSite where appropriate.',
          'module' => 'headers',
          'tags' => %w[cookies headers posture]
        }
      end

      def missing_cookie_flags(cookie)
        value = cookie.downcase
        missing = []
        missing << 'Secure' unless value.include?('secure')
        missing << 'HttpOnly' unless value.include?('httponly')
        missing << 'SameSite' unless value.include?('samesite')
        missing
      end
    end
  end
end
