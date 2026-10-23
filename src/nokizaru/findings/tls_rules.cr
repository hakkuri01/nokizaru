require "../finding"
require "../modules/sslinfo"

module Nokizaru
  module Findings
    # TLS certificate posture findings: expired or soon-to-expire certificates.
    # Consumes the typed sslinfo result. Ports findings/tls_rules.rb.
    module TLSRules
      extend self

      DEFAULT_DAYS_TO_EXPIRY_WARN = 14
      TIME_FORMAT                 = "%b %d %H:%M:%S %Y GMT"

      def call(result : Modules::SSLInfo::Result?) : Array(Finding)
        cert = result.try(&.cert)
        return [] of Finding if cert.nil?

        expiry = parse_time(cert.not_after)
        return [] of Finding if expiry.nil?

        days = (expiry - Time.utc).total_days.round(2)
        return [expired_finding(days, cert.not_after)] if days < 0
        return [expiring_finding(days, cert.not_after)] if days <= DEFAULT_DAYS_TO_EXPIRY_WARN

        [] of Finding
      end

      private def parse_time(value : String) : Time?
        Time.parse_utc(value, TIME_FORMAT)
      rescue
        nil
      end

      private def expired_finding(days : Float64, not_after : String) : Finding
        Finding.new(
          id: "tls.cert_expired",
          severity: "high",
          title: "TLS certificate expired",
          source_module: "sslinfo",
          tags: ["tls", "posture"],
          evidence: "Certificate expired #{days.abs} days ago (#{not_after})",
          recommendation: "Renew and deploy a valid certificate.",
        )
      end

      private def expiring_finding(days : Float64, not_after : String) : Finding
        Finding.new(
          id: "tls.cert_expiring",
          severity: "medium",
          title: "TLS certificate expiring soon",
          source_module: "sslinfo",
          tags: ["tls", "posture"],
          evidence: "Certificate expires in #{days} days (#{not_after})",
          recommendation: "Plan certificate renewal before expiry.",
        )
      end
    end
  end
end
