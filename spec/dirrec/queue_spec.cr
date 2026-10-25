require "../spec_helper"
require "../../src/nokizaru/dirrec/queue"

describe Nokizaru::DirRec::LazyQueue do
  it "walks seeds, base words, then extensions without duplicates" do
    plan = Nokizaru::DirRec::Plan.build("http://x.com", ["admin", "config"], "php", [] of String)
    queue = Nokizaru::DirRec::LazyQueue.new(plan, "http://x.com")
    urls = [] of String
    while url = queue.pop
      urls << url
    end

    urls.should contain("http://x.com/robots.txt")
    urls.should contain("http://x.com/config")
    urls.any?(&.ends_with?("/config.php")).should be_true
    urls.size.should eq(urls.uniq.size)
  end

  it "skips the extension phase when disabled" do
    plan = Nokizaru::DirRec::Plan.build("http://x.com", ["config"], "php", [] of String)
    queue = Nokizaru::DirRec::LazyQueue.new(plan, "http://x.com")
    queue.extension_enabled = false
    urls = [] of String
    while url = queue.pop
      urls << url
    end
    urls.any?(&.ends_with?("/config.php")).should be_false
  end

  it "retains its extension cursor while the phase is suspended" do
    plan = Nokizaru::DirRec::UrlPlan.new([] of String, [] of String, ["first", "second"], ["txt"], 4)
    queue = Nokizaru::DirRec::LazyQueue.new(plan, "http://fixture", false)
    queue.pop.should eq("http://fixture/first")
    queue.pop.should eq("http://fixture/second")
    queue.pop.should be_nil
    queue.extension_enabled = true
    queue.pop.should eq("http://fixture/first.txt")
    queue.extension_enabled = false
    queue.pop.should be_nil
    queue.extension_enabled = true
    queue.pop.should eq("http://fixture/second.txt")
    queue.pop.should be_nil
  end
end
