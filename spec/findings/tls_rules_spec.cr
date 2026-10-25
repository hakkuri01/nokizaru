require "../spec_helper"
require "../../src/nokizaru/findings/tls_rules"

private def result_with(not_after : String) : Nokizaru::Modules::SSLInfo::Result
  cert = Nokizaru::Modules::SSLInfo::CertInfo.new(
    protocol: "TLSv1.3", cipher: nil, subject: {} of String => String, issuer: {} of String => String,
    version: 2, serial_number: "1", not_before: "Jan 01 00:00:00 2020 GMT", not_after: not_after,
    subject_alt_name: nil,
  )
  Nokizaru::Modules::SSLInfo::Result.ok(cert)
end

private def gmt(time : Time) : String
  time.to_s("%b %d %H:%M:%S %Y GMT")
end

describe Nokizaru::Findings::TLSRules do
  it "flags an expired certificate" do
    findings = Nokizaru::Findings::TLSRules.call(result_with(gmt(Time.utc - 3.days)))
    findings.size.should eq(1)
    findings.first.id.should eq("tls.cert_expired")
    findings.first.severity.should eq("high")
  end

  it "flags a certificate expiring within the warning window" do
    findings = Nokizaru::Findings::TLSRules.call(result_with(gmt(Time.utc + 5.days)))
    findings.size.should eq(1)
    findings.first.id.should eq("tls.cert_expiring")
    findings.first.severity.should eq("medium")
  end

  it "says nothing for a certificate valid well into the future" do
    Nokizaru::Findings::TLSRules.call(result_with(gmt(Time.utc + 200.days))).should be_empty
  end

  it "says nothing when there is no certificate" do
    Nokizaru::Findings::TLSRules.call(Nokizaru::Modules::SSLInfo::Result.failure("no tls")).should be_empty
    Nokizaru::Findings::TLSRules.call(nil).should be_empty
  end
end
