# frozen_string_literal: true

require 'time'

module Nokizaru
  module Findings
    # TLS and certificate-focused findings rules
    module TLSRules
      module_function

      DEFAULT_DAYS_TO_EXPIRY_WARN = 14

      def call(ssl_result)
        days, not_after = cert_expiry_window(ssl_result)
        return [] unless days

        return [expired_cert_finding(days, not_after)] if days.negative?
        return [expiring_cert_finding(days, not_after)] if days <= DEFAULT_DAYS_TO_EXPIRY_WARN

        []
      end

      def cert_expiry_window(ssl_result)
        not_after = certificate_not_after(ssl_result)
        return [nil, nil] unless not_after

        expiry = parse_time(not_after)
        return [nil, nil] unless expiry

        [((expiry - Time.now) / 86_400.0).round(2), not_after]
      end

      def certificate_not_after(ssl_result)
        return nil unless ssl_result.is_a?(Hash)

        cert = ssl_result['cert'] || ssl_result
        cert['notAfter'] || cert['not_after'] || cert['not_after_gmt']
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue StandardError
        nil
      end

      def expired_cert_finding(days, not_after)
        {
          'id' => 'tls.cert_expired',
          'severity' => 'high',
          'title' => 'TLS certificate expired',
          'evidence' => "Certificate expired #{days.abs} days ago (#{not_after})",
          'recommendation' => 'Renew and deploy a valid certificate.',
          'module' => 'sslinfo',
          'tags' => %w[tls posture]
        }
      end

      def expiring_cert_finding(days, not_after)
        {
          'id' => 'tls.cert_expiring',
          'severity' => 'medium',
          'title' => 'TLS certificate expiring soon',
          'evidence' => "Certificate expires in #{days} days (#{not_after})",
          'recommendation' => 'Plan certificate renewal before expiry.',
          'module' => 'sslinfo',
          'tags' => %w[tls posture]
        }
      end
    end
  end
end
