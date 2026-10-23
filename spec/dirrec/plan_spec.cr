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
end
