# frozen_string_literal: true

module Nokizaru
  module Findings
    # Port exposure findings rules
    module PortRules
      module_function

      RISKY_PORT_PREFIXES = %w[2375 27017 6379 9200 11211].freeze

      def call(portscan_result)
        return [] unless portscan_result.is_a?(Hash)

        risky_ports = risky_open_ports(portscan_result)
        return [] if risky_ports.empty?

        [sensitive_ports_finding(risky_ports)]
      end

      def open_ports(portscan_result)
        Array(portscan_result['open_ports']).map(&:to_s)
      end

      def risky_open_ports(portscan_result)
        structured = structured_risky_ports(portscan_result)
        return structured unless structured.empty?

        open_ports(portscan_result).select { |port| risky_port?(port) }
      end

      def structured_risky_ports(portscan_result)
        Array(portscan_result['ports']).filter_map do |record|
          next unless structured_risky_port?(record)

          structured_port_label(record)
        end
      end

      def structured_risky_port?(record)
        record.is_a?(Hash) && (record['exposure'] == 'sensitive' || risky_port?(record['port'].to_s))
      end

      def structured_port_label(record)
        service = record['service'].to_s
        port = record['port'].to_s
        category = record['category'].to_s
        label = service.empty? ? port : "#{port} (#{service})"
        category.empty? || category == 'unknown' ? label : "#{label} [#{category}]"
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
