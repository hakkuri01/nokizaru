require "../spec_helper"
require "../../src/nokizaru/wayback/history"

private def url_record(url, timestamp, digest, anchor_reason = nil)
  Nokizaru::Wayback::UrlRecord.new(
    url: url, source: "wayback", timestamp: timestamp,
    snapshot_url: Nokizaru::Wayback::History.replay_url(timestamp, url),
    mimetype: "text/html", statuscode: "200", digest: digest, anchor_reason: anchor_reason,
  )
end

describe Nokizaru::Wayback::History do
  it "selects a historical snapshot near the three-month anchor and a changed snapshot" do
    now = Time.utc(2024, 1, 1)
    anchor = url_record("http://x.com/admin", "20231003000000", "AAA", anchor_reason: "three_months")
    change1 = url_record("http://x.com/api/data", "20230101000000", "D1")
    change2 = url_record("http://x.com/api/data", "20230201000000", "D2")

    historical, changed = Nokizaru::Wayback::History.select([change1, change2], [anchor], now)

    historical.size.should eq(1)
    historical.first.url.should eq("http://x.com/admin")
    historical.first.reasons.should eq(["three_months"])

    api_change = changed.find { |snapshot| snapshot.url == "http://x.com/api/data" }
    api_change.should_not be_nil
    api_change.not_nil!.reasons.should contain("changed")
    api_change.not_nil!.changes.should contain("content")
  end

  it "returns no historical snapshots when anchor records carry no signal" do
    now = Time.utc(2024, 1, 1)
    plain = url_record("http://x.com/about-us/team", "20231003000000", "AAA", anchor_reason: "three_months")
    historical, _changed = Nokizaru::Wayback::History.select([] of Nokizaru::Wayback::UrlRecord, [plain], now)
    historical.should be_empty
  end
end
