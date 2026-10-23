require "../spec_helper"
require "../../src/nokizaru/tui/feed"

private alias Feed = Nokizaru::Tui::Feed
private alias M = Nokizaru::Tui::Messages

describe Nokizaru::Tui::Feed do
  it "drains at most the requested limit, leaving the rest queued" do
    feed = Feed.new(-> { nil.as(String?) })
    feed.live!
    5.times { |i| feed.line("line#{i}") }

    feed.drain(2).size.should eq(2)  # bounded by the limit, not the queue depth
    feed.drain(10).size.should eq(3) # the remainder, in order
    feed.drain(10).should be_empty
  end

  it "holds lines before the scan is live, then queues them tagged" do
    feed = Feed.new(-> { "dns".as(String?) })
    feed.live?.should be_false
    feed.line("setup line")
    feed.drain(10).should be_empty
    feed.live!
    feed.live?.should be_true
    feed.line("result line")
    items = feed.drain(10)
    items.size.should eq(1)
    line = items[0].as(M::FeedLine)
    line.tag.should eq("dns")
    line.text.should eq("result line")
  end

  it "honors a tag override" do
    feed = Feed.new(-> { "dns".as(String?) })
    feed.live!
    feed.tag = "summary"
    feed.line("done summary")
    feed.drain(10)[0].as(M::FeedLine).tag.should eq("summary")
  end

  it "queues lines and lifecycle events in order" do
    feed = Feed.new(-> { "dns".as(String?) })
    feed.live!
    feed.line("a")
    feed.event(M::ScanDone.new(1.5, "/tmp/x", 0))
    items = feed.drain(10)
    items[0].should be_a(M::FeedLine)
    items[1].should be_a(M::ScanDone)
  end

  it "nudges the wake callback when a line or event is posted" do
    nudges = 0
    feed = Feed.new(-> { nil.as(String?) }, -> { nudges += 1; nil })
    feed.live!
    feed.line("x")
    feed.event(M::ScanAborted.new("stopped"))
    nudges.should eq(2)
  end

  it "surfaces the error-marked prelude line when a run aborts in setup" do
    feed = Feed.new(-> { nil.as(String?) })
    feed.line("resolving target")
    feed.line("\e[33m⟦✘⟧\e[0m target unreachable")
    feed.prelude_error.should contain("target unreachable")
  end

  it "caps and ellipsizes an over-long line" do
    feed = Feed.new(-> { "dir".as(String?) })
    feed.live!
    feed.line("y" * (Feed::MAX_LINE_BYTES + 100))
    feed.drain(1)[0].as(M::FeedLine).text.should end_with(Nokizaru::TerminalText::ELLIPSIS)
  end
end
