require "../spec_helper"
require "../../src/nokizaru/dirrec/plan"

describe Nokizaru::DirRec::Plan do
  it "builds seeds from high-signal and crawler paths, prioritized words, and extensions" do
    plan = Nokizaru::DirRec::Plan.build("http://x.com", ["admin", "index", "logo.png"], "php, bak", ["/custom"])
    plan.seed_urls.should contain("http://x.com/admin")
    plan.seed_urls.should contain("http://x.com/custom")
    plan.extensions.should eq(["php", "bak"])
    plan.words.should contain("admin")
    plan.estimated_total.should be > 0
  end

  it "seeds context paths (wayback/JS feeds) without treating them as crawler corroboration" do
    plan = Nokizaru::DirRec::Plan.build("http://x.com", ["admin"], "", ["/crawled"], ["/legacy/report-q3-2019"])
    plan.seed_urls.should contain("http://x.com/legacy/report-q3-2019")
    plan.seed_urls.should contain("http://x.com/crawled")
    # context seeds are scanned but are not part of the crawler set used for
    # corroboration, so a wayback-only path is not falsely marked crawler-seen.
    plan.crawler_paths.should eq(["/crawled"])
  end

  it "appends absolute alt-origin seed URLs (portscan-derived) as-is" do
    plan = Nokizaru::DirRec::Plan.build("http://x.com", ["admin"], "", [] of String, [] of String, ["https://x.com:8443/admin", "https://x.com:8443/"])
    plan.seed_urls.should contain("https://x.com:8443/admin")
    plan.seed_urls.should contain("https://x.com:8443/")
  end
end
