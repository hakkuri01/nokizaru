require "../spec_helper"
require "../../src/nokizaru/dirrec/confidence"

private def confidence(url, status, sample, baseline = nil, target = "http://x.com")
  Nokizaru::DirRec::Confidence.finding_confidence(url, status, sample, baseline, target).level
end

describe Nokizaru::DirRec::Confidence do
  it "demotes a soft-404 signature match to low" do
    sample = Nokizaru::DirRec::Sample.new(200, content_type: "text/html", body_length: 100, fingerprint: "abc")
    baseline = Nokizaru::DirRec::Baseline.new(200, content_type: "text/html", body_length: 100, tolerance: 128, fingerprint: "abc")
    confidence("http://x.com/whatever", 200, sample, baseline).should eq("low")
  end

  it "confirms high-signal content and sensitive high-signal paths" do
    rich = Nokizaru::DirRec::Sample.new(200, content_type: "text/html", body_length: 500, fingerprint: "z")
    confidence("http://x.com/admin", 200, rich).should eq("confirmed")
    confidence("http://x.com/.git/HEAD", 403, Nokizaru::DirRec::Sample.new(403)).should eq("confirmed")
  end

  it "marks meaningful non-signal content as likely and an auth redirect as confirmed" do
    rich = Nokizaru::DirRec::Sample.new(200, content_type: "text/html", body_length: 500, fingerprint: "z")
    confidence("http://x.com/reports", 200, rich).should eq("likely")
    auth = Nokizaru::DirRec::Sample.new(302, redirect_pattern: "auth_entry:https:x.com")
    confidence("http://x.com/secret", 302, auth).should eq("confirmed")
  end

  it "recognizes the sensitive-status reasons" do
    Nokizaru::DirRec::Confidence.sensitive_status_reason?("sensitive_status").should be_true
    Nokizaru::DirRec::Confidence.sensitive_status_reason?("meaningful_sensitive_status").should be_true
    Nokizaru::DirRec::Confidence.sensitive_status_reason?("high_signal_path").should be_false
  end
end
