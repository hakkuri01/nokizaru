require "../spec_helper"
require "../../src/nokizaru/findings/header_rules"

private def result_with(headers : Hash(String, String)) : Nokizaru::Modules::Headers::Result
  profile = Nokizaru::TargetIntel::Profile.new("http://x", "http://x", "none", "low", "r")
  Nokizaru::Modules::Headers::Result.ok(headers, profile)
end

describe Nokizaru::Findings::HeaderRules do
  it "flags each missing security header" do
    findings = Nokizaru::Findings::HeaderRules.call(result_with({} of String => String))
    ids = findings.map(&.id)
    ids.should contain("headers.missing_strict_transport_security")
    ids.should contain("headers.missing_content_security_policy")
    ids.should contain("headers.missing_x_frame_options")
    findings.all? { |f| f.source_module == "headers" }.should be_true
  end

  it "does not flag a header that is present" do
    headers = {"content-security-policy" => "default-src 'self'"}
    ids = Nokizaru::Findings::HeaderRules.call(result_with(headers)).map(&.id)
    ids.should_not contain("headers.missing_content_security_policy")
  end

  it "flags a cookie missing recommended flags" do
    headers = {"set-cookie" => "sessionid=abc; Path=/"}
    cookie_findings = Nokizaru::Findings::HeaderRules.call(result_with(headers))
      .select { |f| f.title == "Cookie missing recommended flags" }
    cookie_findings.size.should eq(1)
    cookie_findings.first.evidence.not_nil!.should contain("Secure")
    cookie_findings.first.evidence.not_nil!.should contain("HttpOnly")
  end

  it "does not flag a fully-secured cookie" do
    headers = {"set-cookie" => "sessionid=abc; Secure; HttpOnly; SameSite=Strict"}
    Nokizaru::Findings::HeaderRules.call(result_with(headers))
      .any? { |f| f.title == "Cookie missing recommended flags" }.should be_false
  end

  it "returns nothing for a failed headers result" do
    profile = Nokizaru::TargetIntel::Profile.new("http://x", "http://x", "none", "low", "r")
    failed = Nokizaru::Modules::Headers::Result.failure("boom", profile)
    Nokizaru::Findings::HeaderRules.call(failed).should be_empty
  end
end
