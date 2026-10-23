require "../spec_helper"
require "../../src/nokizaru/wayback/normalize"

describe Nokizaru::Wayback::Normalize do
  describe ".sanitized_url_record" do
    it "accepts a clean http URL and rejects userinfo and controls" do
      Nokizaru::Wayback::Normalize.sanitized_url_record("http://x.com/a").should_not be_nil
      Nokizaru::Wayback::Normalize.sanitized_url_record("http://user:pass@x.com/a").should be_nil
      Nokizaru::Wayback::Normalize.sanitized_url_record("ftp://x.com/a").should be_nil
      Nokizaru::Wayback::Normalize.sanitized_url_record("").should be_nil
    end
  end

  describe ".filter_urls" do
    it "keeps the exact-host URLs and drops the rest" do
      urls = ["http://x.com/a", "http://evil.com/b", "http://x.com/a"]
      kept = Nokizaru::Wayback::Normalize.filter_urls(urls, target: "http://x.com/", include_noise: true, exact_host: true)
      kept.should eq(["http://x.com/a"])
    end
  end

  describe ".signal_labels / .noise_url?" do
    it "labels API, interesting-path, javascript, and sensitive-file URLs" do
      Nokizaru::Wayback::Normalize.signal_labels("http://x.com/api/v1/users").should contain("api")
      Nokizaru::Wayback::Normalize.signal_labels("http://x.com/admin").should contain("interesting_path")
      Nokizaru::Wayback::Normalize.signal_labels("http://x.com/app.js").should contain("javascript")
      Nokizaru::Wayback::Normalize.signal_labels("http://x.com/.env").should contain("sensitive_file")
      Nokizaru::Wayback::Normalize.noise_url?("http://x.com/logo.png").should be_true
    end
  end

  describe ".triage" do
    it "buckets URLs and counts interesting parameters" do
      urls = ["http://x.com/admin", "http://x.com/api/users", "http://x.com/p?token=abc", "http://x.com/logo.png"]
      triage = Nokizaru::Wayback::Normalize.triage(urls)
      triage.interesting_path_urls.should contain("http://x.com/admin")
      triage.api_urls.should contain("http://x.com/api/users")
      triage.interesting_parameter_urls.should contain("http://x.com/p?token=abc")
      triage.parameter_counts["token"].should eq(1)
      triage.review_urls.should contain("http://x.com/admin")
    end
  end

  describe ".original_url_from_archive_snapshot" do
    it "extracts the original URL from a replay URL" do
      replay = "https://web.archive.org/web/20230101000000/http://x.com/a"
      Nokizaru::Wayback::Normalize.original_url_from_archive_snapshot(replay).should eq("http://x.com/a")
      Nokizaru::Wayback::Normalize.original_url_from_archive_snapshot("http://x.com/a").should eq("")
    end
  end
end
