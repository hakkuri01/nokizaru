require "../spec_helper"
require "../../src/nokizaru/findings/engine"

private def expired_sslinfo : Nokizaru::Modules::SSLInfo::Result
  cert = Nokizaru::Modules::SSLInfo::CertInfo.new(
    protocol: "TLSv1.3", cipher: "x", subject: {} of String => String, issuer: {} of String => String,
    version: 2, serial_number: "1", not_before: "Jan 01 00:00:00 2020 GMT",
    not_after: (Time.utc - 3.days).to_s("%b %d %H:%M:%S %Y GMT"), subject_alt_name: nil,
  )
  Nokizaru::Modules::SSLInfo::Result.ok(cert)
end

describe Nokizaru::Findings::Engine do
  it "aggregates findings across the available module rules" do
    meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "t")
    run = Nokizaru::RunState.new(meta)
    profile = Nokizaru::TargetIntel::Profile.new("https://example.com", "https://example.com", "none", "low", "r")
    run.modules.headers = Nokizaru::Modules::Headers::Result.ok({} of String => String, profile)
    run.modules.sslinfo = expired_sslinfo

    findings = Nokizaru::Findings::Engine.run(run)
    ids = findings.map(&.id)
    ids.should contain("headers.missing_content_security_policy")
    ids.should contain("tls.cert_expired")
  end

  it "returns nothing when no module has run" do
    meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "t")
    Nokizaru::Findings::Engine.run(Nokizaru::RunState.new(meta)).should be_empty
  end
end
