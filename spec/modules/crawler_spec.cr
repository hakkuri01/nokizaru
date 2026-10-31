require "../spec_helper"
require "../support/http_test_server"
require "compress/gzip"
require "io/memory"
require "../../src/nokizaru/modules/crawler"
require "../../src/nokizaru/run_state"

private LANDING = %(<html><body><a href="/admin/panel">a</a><a href="https://evil.com/x">e</a><link rel="stylesheet" href="/style.css"><script src="/app.js"></script><img src="/logo.png"></body></html>)
private SITEMAP = %(<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>http://127.0.0.1/page1</loc></url></urlset>)
private APPJS   = %(var api = "http://127.0.0.1/api/data"; fetch(api);)

private def gzip_bytes(xml : String) : Bytes
  buffer = IO::Memory.new
  Compress::Gzip::Writer.open(buffer, &.print(xml))
  buffer.to_slice.dup
end

describe Nokizaru::Modules::Crawler do
  it "crawls the page, robots, sitemap, and JavaScript into a typed result" do
    handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/"            then context.response.print(LANDING)
      when "/robots.txt"  then context.response.print("User-agent: *\nDisallow: /secret\nSitemap: /sitemap.xml\n")
      when "/sitemap.xml" then context.response.print(SITEMAP)
      when "/app.js"      then context.response.print(APPJS)
      else                     context.response.print("ok")
      end
    end

    HttpTestServer.with_server(handler) do |base|
      result = Nokizaru::Modules::Crawler.collect("#{base}/", Nokizaru::Http::Pool.new)

      result.status.should eq("ok")
      result.target.original.should eq("#{base}/")
      result.target.reanchored?.should be_false
      result.active_user_agent.should eq(Nokizaru::Crawler::USER_AGENT)
      result.fetch.not_nil!.primary.status.should eq(200)

      result.internal_links.any?(&.ends_with?("/admin/panel")).should be_true
      result.external_links.should contain("https://evil.com/x")
      result.css_links.any?(&.ends_with?("/style.css")).should be_true
      result.js_links.any?(&.ends_with?("/app.js")).should be_true
      result.images.any?(&.ends_with?("/logo.png")).should be_true
      result.robots_links.any?(&.ends_with?("/secret")).should be_true

      result.urls_inside_sitemap.should contain("http://127.0.0.1/page1")
      result.urls_inside_js.should contain("http://127.0.0.1/api/data")

      result.stats.crawl_mode.should eq("standard")
      result.stats.total_unique.not_nil!.should be > 0
      result.high_signal_urls.not_nil!.any?(&.ends_with?("/admin/panel")).should be_true
    end
  end

  it "inflates a gzipped sitemap child reached through a sitemap index" do
    base_url = ""
    child = gzip_bytes(%(<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>http://127.0.0.1/gzpage</loc></url></urlset>))
    handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/"
        context.response.print("<html></html>")
      when "/robots.txt"
        context.response.status_code = 404
      when "/sitemap.xml"
        context.response.print(%(<?xml version="1.0"?><sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><sitemap><loc>#{base_url}/child.xml.gz</loc></sitemap></sitemapindex>))
      when "/child.xml.gz"
        context.response.write(child)
      else
        context.response.status_code = 404
      end
    end

    HttpTestServer.with_server(handler) do |base|
      base_url = base
      result = Nokizaru::Modules::Crawler.collect("#{base}/", Nokizaru::Http::Pool.new)
      result.status.should eq("ok")
      result.urls_inside_sitemap.should contain("http://127.0.0.1/gzpage")
    end
  end

  it "returns a failure result with an empty stats object when the target is unreachable" do
    port = HttpTestServer.closed_port
    result = Nokizaru::Modules::Crawler.collect("http://127.0.0.1:#{port}/", Nokizaru::Http::Pool.new)

    result.status.should eq("failed")
    result.error.should_not be_nil
    result.failure_reason.should eq("transport_error")
    JSON.parse(result.to_json)["stats"].as_h.empty?.should be_true

    run = Nokizaru::RunState.new(Nokizaru::Meta.new(version: "1.0.0", target: "x", started_at: "t"))
    run.modules.crawler = result
    run.modules.crawler.should_not be_nil
  end
end

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

describe "Nokizaru::Modules::Crawler.present" do
  it "renders the re-anchor row, bucket counts, and bounded previews" do
    target = Nokizaru::Crawler::Target.new("http://x/", "http://x/", false, "", "ok")
    result = Nokizaru::Crawler::Result.new(target, "ok")
    result.robots_links = ["http://x/secret"]
    result.internal_links = (1..9).map { |n| "http://x/page#{n}" }
    result.external_links = ["https://evil.com/a"]
    result.js_links = ["http://x/app.js"]
    result.urls_inside_js = ["http://x/api/data"]

    text = present_capture { Nokizaru::Modules::Crawler.present(result) }

    text.should contain("Re-Anchor")
    text.should contain("http://x/ (ok)")
    text.should contain("Extracting internal links")
    text.should contain("Internal Links Preview")
    text.should contain("http://x/page1")
    text.should contain("More") # 9 internal links > PREVIEW_LIMIT, so one remaining
    text.should contain("External Links Preview")
    text.should contain("https://evil.com/a")
  end
end
