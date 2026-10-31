require "../finding"
require "../modules/portscan"

module Nokizaru
  module Findings
    # Flags open ports that commonly front unauthenticated sensitive services
    # (Docker API, MongoDB, Redis, Elasticsearch, Memcached). Consumes the typed
    # portscan result and skips tarpit-downgraded (low-confidence) ports, because
    # an all-accept middlebox would otherwise report every sensitive service as
    # exposed.
    module PortRules
      extend self

      # Matched as a prefix of the port number, as the Ruby rule did.
      RISKY_PORT_PREFIXES = %w[2375 27017 6379 9200 11211]

      def call(result : Modules::PortScan::Result?) : Array(Finding)
        return [] of Finding if result.nil?

        risky = risky_ports(result)
        risky.empty? ? [] of Finding : [sensitive_ports_finding(risky)]
      end

      private def risky_ports(result : Modules::PortScan::Result) : Array(String)
        result.ports.compact_map do |record|
          label_for(record) if risky?(record)
        end
      end

      private def risky?(record : Portscan::PortRecord) : Bool
        return false if record.confidence == "low"

        record.exposure == "sensitive" || risky_port?(record.port.to_s)
      end

      private def risky_port?(port : String) : Bool
        RISKY_PORT_PREFIXES.any? { |prefix| port.starts_with?(prefix) }
      end

      private def label_for(record : Portscan::PortRecord) : String
        port = record.port.to_s
        label = record.service.empty? ? port : "#{port} (#{record.service})"
        category = record.category
        category.empty? || category == "unknown" ? label : "#{label} [#{category}]"
      end

      private def sensitive_ports_finding(risky : Array(String)) : Finding
        Finding.new(
          id: "ports.sensitive_open",
          severity: "medium",
          title: "Potentially sensitive service ports detected",
          source_module: "portscan",
          tags: ["ports", "posture"],
          evidence: "Open ports include: #{risky.join(", ")}",
          recommendation: "Validate exposure is intended; restrict access with network controls where possible.",
        )
      end
    end
  end
end
