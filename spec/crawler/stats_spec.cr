require "../spec_helper"
require "json"
require "../../src/nokizaru/crawler/stats"
require "../../src/nokizaru/crawler/result"

private def target
  Nokizaru::Crawler::Target.new(
    original: "https://x.com/", effective: "https://x.com/",
    reanchored: false, reason: "", reason_code: "no-redirect",
  )
end

describe Nokizaru::Crawler::Statistics do
  it "counts the buckets, ranks high-signal URLs, and carries the crawl mode" do
    result = Nokizaru::Crawler::Result.new(target, "ok")
    result.internal_links = ["https://x.com/admin/panel", "https://x.com/about", "https://x.com/login?x=1"]
    result.images = ["https://x.com/a.png"]

    stats = Nokizaru::Crawler::Statistics.calculate(result, "standard", [] of String)
    stats.internal_count.should eq(3)
    stats.images_count.should eq(1)
    stats.total_unique.should eq(4)
    stats.crawl_mode.should eq("standard")

    ranked = stats.high_signal_urls.not_nil!
    ranked.first.should eq("https://x.com/admin/panel")
    ranked.should contain("https://x.com/login?x=1")
    ranked.should_not contain("https://x.com/about")
    ranked.should_not contain("https://x.com/a.png")
  end

  it "draws the top-level high_signal set from the four signal buckets" do
    result = Nokizaru::Crawler::Result.new(target, "ok")
    result.robots_links = ["https://x.com/wp-admin/"]
    result.external_links = ["https://evil.com/admin/"]

    high = Nokizaru::Crawler::Statistics.high_signal(result)
    high.should contain("https://x.com/wp-admin/")
    high.should_not contain("https://evil.com/admin/")
  end

  it "serializes an unpopulated Stats as an empty object" do
    JSON.parse(Nokizaru::Crawler::Stats.new.to_json).as_h.empty?.should be_true
  end
end
