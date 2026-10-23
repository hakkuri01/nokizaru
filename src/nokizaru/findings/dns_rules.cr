require "../finding"
require "../modules/dns"

module Nokizaru
  module Findings
    # DNS email-posture findings: a missing SPF (a TXT record with v=spf1) or
    # DMARC (a _dmarc TXT record with v=DMARC1). Consumes the typed dns result.
    # Ports findings/dns_rules.rb: when the module ran at all (even on an
    # unresolved domain, whose records are empty) an absent marker is flagged;
    # a module that did not run (nil) yields nothing.
    module DNSRules
      extend self

      def call(result : Modules::DnsEnumeration::Result?) : Array(Finding)
        return [] of Finding if result.nil?

        findings = [] of Finding
        findings << missing_spf unless present?(result, "TXT", "v=spf1")
        findings << missing_dmarc unless present?(result, "DMARC", "v=dmarc1")
        findings
      end

      private def present?(result : Modules::DnsEnumeration::Result, key : String, marker : String) : Bool
        values = result.records[key]?
        return false if values.nil?

        values.any?(&.downcase.includes?(marker))
      end

      private def missing_spf : Finding
        Finding.new(
          id: "dns.missing_spf",
          severity: "low",
          title: "SPF record not detected",
          source_module: "dns",
          tags: ["dns", "email", "posture"],
          evidence: "No TXT record containing v=spf1 was observed.",
          recommendation: "If the domain sends email, publish an SPF policy.",
        )
      end

      private def missing_dmarc : Finding
        Finding.new(
          id: "dns.missing_dmarc",
          severity: "low",
          title: "DMARC record not detected",
          source_module: "dns",
          tags: ["dns", "email", "posture"],
          evidence: "No _dmarc TXT record containing v=DMARC1 was observed.",
          recommendation: "If the domain sends email, publish a DMARC policy.",
        )
      end
    end
  end
end
