# frozen_string_literal: true

module Nokizaru
  module Findings
    # Port exposure findings rules
    module PortRules
      module_function

      RISKY_PORT_PREFIXES = %w[2375 27017 6379 9200 11211].freeze

      def call(portscan_result)
        return [] unless portscan_result.is_a?(Hash)

        risky_ports = open_ports(portscan_result).select { |port| risky_port?(port) }
        return [] if risky_ports.empty?

        [sensitive_ports_finding(risky_ports)]
      end

      def open_ports(portscan_result)
        Array(portscan_result['open_ports']).map(&:to_s)
      end

      def risky_port?(port)
        RISKY_PORT_PREFIXES.any? { |prefix| port.start_with?(prefix) }
      end

      def sensitive_ports_finding(risky_ports)
        {
          'id' => 'ports.sensitive_open',
          'severity' => 'medium',
          'title' => 'Potentially sensitive service ports detected',
          'evidence' => "Open ports include: #{risky_ports.join(', ')}",
          'recommendation' => 'Validate exposure is intended; restrict access with network controls where possible.',
          'module' => 'portscan',
          'tags' => %w[ports posture]
        }
      end
    end
  end
end
