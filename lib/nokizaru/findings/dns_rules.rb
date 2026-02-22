# frozen_string_literal: true

module Nokizaru
  module Findings
    # DNS-focused findings rules
    module DNSRules
      module_function

      def call(dns_result)
        return [] unless dns_result.is_a?(Hash)

        findings = []
        findings << missing_spf_finding unless spf_record_present?(dns_result)
        findings << missing_dmarc_finding unless dmarc_record_present?(dns_result)
        findings
      end

      def spf_record_present?(dns_result)
        txt_records = Array(dns_result.dig('records', 'TXT')) + Array(dns_result['txt'])
        txt_records.any? { |record| record.to_s.downcase.include?('v=spf1') }
      end

      def dmarc_record_present?(dns_result)
        dmarc_records = Array(dns_result.dig('records', 'DMARC')) + Array(dns_result['dmarc'])
        dmarc_records.any? { |record| record.to_s.downcase.include?('v=dmarc1') }
      end

      def missing_spf_finding
        {
          'id' => 'dns.missing_spf',
          'severity' => 'low',
          'title' => 'SPF record not detected',
          'evidence' => 'No TXT record containing v=spf1 was observed.',
          'recommendation' => 'If the domain sends email, publish an SPF policy.',
          'module' => 'dns',
          'tags' => %w[dns email posture]
        }
      end

      def missing_dmarc_finding
        {
          'id' => 'dns.missing_dmarc',
          'severity' => 'low',
          'title' => 'DMARC record not detected',
          'evidence' => 'No _dmarc TXT record containing v=DMARC1 was observed.',
          'recommendation' => 'If the domain sends email, publish a DMARC policy.',
          'module' => 'dns',
          'tags' => %w[dns email posture]
        }
      end
    end
  end
end
