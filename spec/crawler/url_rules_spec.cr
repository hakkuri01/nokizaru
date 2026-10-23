require "../spec_helper"
require "../../src/nokizaru/crawler/url_rules"

describe Nokizaru::Crawler::UrlRules do
  describe ".url_filter" do
    it "resolves relative links under the target path" do
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/app", "page").should eq("https://x.com/app/page")
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/app/", "/root").should eq("https://x.com/root")
    end

    it "drops in-page, javascript, and mailto links" do
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/", "#frag").should be_nil
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/", "javascript:alert(1)").should be_nil
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/", "mailto:a@b.com").should be_nil
      Nokizaru::Crawler::UrlRules.url_filter("https://x.com/", nil).should be_nil
    end
  end

  describe ".internal_link / .external_link" do
    it "keeps in-scope links as internal and out-of-scope absolute links as external" do
      Nokizaru::Crawler::UrlRules.internal_link("https://x.com/", "x.com", "/a").should eq("https://x.com/a")
      Nokizaru::Crawler::UrlRules.internal_link("https://x.com/", "x.com", "https://evil.com/a").should be_nil
      Nokizaru::Crawler::UrlRules.external_link("x.com", "https://evil.com/a").should eq("https://evil.com/a")
      Nokizaru::Crawler::UrlRules.external_link("x.com", "https://www.x.com/a").should be_nil
      Nokizaru::Crawler::UrlRules.external_link("x.com", "/a").should be_nil
    end
  end

  describe ".sitemap_candidate? / .scoped_sitemap_candidates" do
    it "recognizes .xml and .xml.gz paths and scopes them to the target" do
      Nokizaru::Crawler::UrlRules.sitemap_candidate?("https://x.com/sitemap.xml").should be_true
      Nokizaru::Crawler::UrlRules.sitemap_candidate?("https://x.com/s.xml.gz").should be_true
      Nokizaru::Crawler::UrlRules.sitemap_candidate?("https://x.com/page.html").should be_false

      urls = ["https://x.com/a.xml", "https://evil.com/b.xml", "https://x.com/c.html"]
      Nokizaru::Crawler::UrlRules.scoped_sitemap_candidates(urls, "x.com").should eq(["https://x.com/a.xml"])
    end
  end

  describe ".base_url_for" do
    it "builds the origin and drops a default port" do
      Nokizaru::Crawler::UrlRules.base_url_for("https://x.com:443/a/b").should eq("https://x.com")
      Nokizaru::Crawler::UrlRules.base_url_for("http://x.com:8080/a").should eq("http://x.com:8080")
    end
  end

  describe ".cap_links" do
    it "de-duplicates in first-seen order and caps" do
      Nokizaru::Crawler::UrlRules.cap_links(["a", "b", "a", "c", "d"], 3).should eq(["a", "b", "c"])
    end
  end
end
