# frozen_string_literal: true

require_relative 'header_rules'
require_relative 'tls_rules'
require_relative 'dns_rules'
require_relative 'port_rules'
require_relative 'directory_rules'

module Nokizaru
  module Findings
    # Rule dispatcher for normalized findings generation
    module Rules
      module_function

      def headers_findings(headers_result)
        HeaderRules.call(headers_result)
      end

      def tls_findings(ssl_result)
        TLSRules.call(ssl_result)
      end

      def dns_findings(dns_result)
        DNSRules.call(dns_result)
      end

      def port_findings(portscan_result)
        PortRules.call(portscan_result)
      end

      def dir_findings(dir_result)
        DirectoryRules.call(dir_result)
      end
    end
  end
end
