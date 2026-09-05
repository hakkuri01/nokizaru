# frozen_string_literal: true

require_relative 'header_rules'
require_relative 'tls_rules'
require_relative 'dns_rules'
require_relative 'port_rules'
require_relative 'directory_rules'

module Nokizaru
  module Findings
    class Engine
      def run(run)
        modules = run.fetch('modules', {})
        findings = collect_findings(modules)
        normalize_findings(findings)
      end

      private

      def collect_findings(modules)
        [
          HeaderRules.call(modules['headers']),
          TLSRules.call(modules['sslinfo']),
          DNSRules.call(modules['dns']),
          PortRules.call(modules['portscan']),
          DirectoryRules.call(modules['directory_enum'])
        ].flatten.compact
      end

      def normalize_findings(findings)
        findings.each_with_index.map do |finding, index|
          finding['id'] ||= "finding.#{index}"
          finding['severity'] ||= 'low'
          finding
        end
      end
    end
  end
end
