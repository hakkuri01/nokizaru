require "../spec_helper"
require "../../src/nokizaru/crawler/budget"

private def surface(internal = 0, external = 0, images = 0, sitemap = 0, js = 0, robots = 0)
  Nokizaru::Crawler::Surface.new(internal, external, images, sitemap, js, robots)
end

describe Nokizaru::Crawler::Budget do
  it "stays standard for a light surface" do
    budget = Nokizaru::Crawler::Budget.new
    budget.apply(surface(internal: 10, js: 2, robots: 5))
    budget.degraded?.should be_false
    budget.crawl_mode.should eq("standard")
    budget.max_sitemaps.should eq(Nokizaru::Crawler::MAX_SITEMAPS)
  end

  it "degrades on an extreme internal-link surface and lowers the caps" do
    budget = Nokizaru::Crawler::Budget.new
    budget.apply(surface(internal: Nokizaru::Crawler::EXTREME_INTERNAL_LINKS_THRESHOLD))
    budget.degraded?.should be_true
    budget.crawl_mode.should eq("degraded")
    budget.notes.should eq(["heavy_target"])
    budget.max_sitemaps.should eq(Nokizaru::Crawler::DEGRADED_MAX_SITEMAPS)
    budget.max_js_urls_total.should eq(Nokizaru::Crawler::DEGRADED_MAX_JS_URLS_TOTAL)
  end

  it "degrades when two heavy indicators trip together" do
    budget = Nokizaru::Crawler::Budget.new
    budget.apply(surface(
      internal: Nokizaru::Crawler::HEAVY_INTERNAL_LINKS_THRESHOLD,
      js: Nokizaru::Crawler::HEAVY_JS_LINKS_THRESHOLD,
    ))
    budget.degraded?.should be_true
  end

  it "marks the wall-clock note and reports exhaustion for a past deadline" do
    budget = Nokizaru::Crawler::Budget.new(Time.instant - 1.second)
    budget.exhausted?.should be_true
    budget.notes.should contain("wall_clock_budget_exhausted")
    budget.status_degraded?.should be_true
  end
end
