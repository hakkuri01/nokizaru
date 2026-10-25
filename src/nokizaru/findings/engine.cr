require "../finding"
require "../run_state"
require "./header_rules"
require "./tls_rules"
require "./dns_rules"
require "./port_rules"
require "./directory_rules"
require "./adversary_rules"

module Nokizaru
  module Findings
    # Runs every available rule over the typed run state and returns the combined
    # findings. Each rule consumes one module's typed result. The directory rule
    # is added here when that module lands (its result type does not exist yet),
    # so the aggregation grows one line at a time. Ports findings/engine.rb; the
    # Ruby normalize step (defaulting a missing id or severity) is unnecessary
    # because a typed Finding always carries both.
    module Engine
      extend self

      def run(run : RunState) : Array(Finding)
        findings = [] of Finding
        findings.concat(HeaderRules.call(run.modules.headers))
        findings.concat(TLSRules.call(run.modules.sslinfo))
        findings.concat(DNSRules.call(run.modules.dns))
        findings.concat(PortRules.call(run.modules.portscan))
        findings.concat(DirectoryRules.call(run.modules.directory_enum))
        findings.concat(AdversaryRules.call(run.modules.directory_enum, run.modules.headers))
        findings
      end
    end
  end
end
