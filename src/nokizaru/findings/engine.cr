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
    # findings. Each rule consumes one module's typed result, so a module that
    # did not run contributes nothing instead of producing a finding about
    # missing data. No normalize step is needed: a typed Finding always carries
    # an id and a severity, so there is nothing to default.
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
