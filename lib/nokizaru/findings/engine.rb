# frozen_string_literal: true

require_relative 'rules'

module Nokizaru
  module Findings
    # Nokizaru::Findings::Engine implementation
    class Engine
      # Coordinate the end to end scan workflow from setup to final output
      def run(run)
        modules = run.fetch('modules', {})
        findings = collect_findings(modules)
        normalize_findings(findings)
      end

      private

      def collect_findings(modules)
        [
          Rules.headers_findings(modules['headers']),
          Rules.tls_findings(modules['sslinfo']),
          Rules.dns_findings(modules['dns']),
          Rules.port_findings(modules['portscan']),
          Rules.dir_findings(modules['directory_enum'])
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
