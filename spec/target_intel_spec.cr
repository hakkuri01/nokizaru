require "./spec_helper"
require "../src/nokizaru/target_intel"

describe Nokizaru::TargetIntel do
  describe ".same_scope_host?" do
    it "treats a shared registrable domain as in scope" do
      Nokizaru::TargetIntel.same_scope_host?("www.example.com", "api.example.com").should be_true
      Nokizaru::TargetIntel.same_scope_host?("a.b.example.co.uk", "example.co.uk").should be_true
    end

    it "treats different registrable domains as out of scope" do
      Nokizaru::TargetIntel.same_scope_host?("example.com", "example.org").should be_false
      Nokizaru::TargetIntel.same_scope_host?("example.com", "evil.com").should be_false
    end

    it "treats identical hosts as in scope, IPs only when equal" do
      Nokizaru::TargetIntel.same_scope_host?("1.2.3.4", "1.2.3.4").should be_true
      Nokizaru::TargetIntel.same_scope_host?("1.2.3.4", "1.2.3.5").should be_false
      Nokizaru::TargetIntel.same_scope_host?("", "example.com").should be_false
    end
  end

  describe ".registrable_domain" do
    it "delegates to the PSL" do
      Nokizaru::TargetIntel.registrable_domain("deep.sub.example.co.uk").should eq("example.co.uk")
    end
  end

  describe ".ip_address?" do
    it "recognizes IP literals and rejects hostnames" do
      Nokizaru::TargetIntel.ip_address?("10.0.0.1").should be_true
      Nokizaru::TargetIntel.ip_address?("::1").should be_true
      Nokizaru::TargetIntel.ip_address?("example.com").should be_false
    end
  end

  describe ".resolve_location" do
    it "resolves relative and absolute redirect targets" do
      Nokizaru::TargetIntel.resolve_location("https://x.com/a/b", "../c").should eq("https://x.com/c")
      Nokizaru::TargetIntel.resolve_location("https://x.com/a", "https://y.com/z").should eq("https://y.com/z")
    end
  end

  describe ".same_origin?" do
    it "compares scheme, host, and effective port" do
      Nokizaru::TargetIntel.same_origin?("https://x.com/a", "https://x.com:443/b").should be_true
      Nokizaru::TargetIntel.same_origin?("https://x.com", "http://x.com").should be_false
    end
  end

  describe ".scope_check" do
    it "builds a predicate usable as the pool redirect scope" do
      Nokizaru::TargetIntel.scope_check.call("www.example.com", "example.com").should be_true
    end
  end

  describe ".normalize_http_url" do
    it "lowercases scheme and host, drops the fragment and default port" do
      Nokizaru::TargetIntel.normalize_http_url("HTTP://Example.COM:80/A#frag").should eq("http://example.com/A")
      Nokizaru::TargetIntel.normalize_http_url("https://x.com").should eq("https://x.com/")
      Nokizaru::TargetIntel.normalize_http_url("https://x.com:8443/p?q=1").should eq("https://x.com:8443/p?q=1")
    end

    it "rejects non-HTTP(S) URLs, hostless URLs, and userinfo" do
      Nokizaru::TargetIntel.normalize_http_url("ftp://x.com/").should be_nil
      Nokizaru::TargetIntel.normalize_http_url("mailto:a@b.com").should be_nil
      Nokizaru::TargetIntel.normalize_http_url("http://user:pass@x.com/").should be_nil
    end
  end

  describe ".redirect_target" do
    it "follows a same-scope redirect" do
      decision = Nokizaru::TargetIntel.redirect_target("https://www.x.com/a", "https://x.com/b")
      decision.next_url.should eq("https://x.com/b")
      decision.stop_reason.should be_nil
    end

    it "flags an out-of-scope Location as a canonical handoff" do
      decision = Nokizaru::TargetIntel.redirect_target("https://x.com/a", "https://evil.com/")
      decision.stop_reason.should eq("canonical_handoff")
      decision.canonical_handoff.should eq("https://evil.com/")
    end

    it "refuses an HTTPS to HTTP downgrade" do
      decision = Nokizaru::TargetIntel.redirect_target("https://x.com/a", "http://x.com/b")
      decision.stop_reason.should eq("unsafe_redirect")
    end
  end

  describe ".reanchor_decision" do
    it "re-anchors a high-confidence HTTP to HTTPS upgrade" do
      profile = Nokizaru::TargetIntel::Profile.new(
        "http://x.com/", "https://x.com/", "http_to_https", "high",
        "Canonical HTTP to HTTPS redirect detected", "https://x.com/"
      )
      decision = Nokizaru::TargetIntel.reanchor_decision("http://x.com/", profile)
      decision.reanchor?.should be_true
      decision.effective_target.should eq("https://x.com/")
      decision.reason_code.should eq("http->https")
    end

    it "does not re-anchor a plain no-redirect target" do
      profile = Nokizaru::TargetIntel::Profile.new(
        "https://x.com/", "https://x.com/", "none", "low", "No stable redirect behavior detected"
      )
      decision = Nokizaru::TargetIntel.reanchor_decision("https://x.com/", profile)
      decision.reanchor?.should be_false
      decision.effective_target.should eq("https://x.com/")
      decision.reason_code.should eq("no-redirect")
    end
  end
end
