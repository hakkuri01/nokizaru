require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/sitemaps"

private class OrderedSitemapFixture
  ROOTS  = ["/z-root.xml", "/a-root.xml"]
  LEAVES = ["/z3.xml", "/z1.xml", "/z2.xml", "/z0.xml", "/a3.xml", "/a1.xml", "/a2.xml", "/a0.xml"]

  property base = ""
  getter counts = Hash(String, Int32).new(0)
  getter completions = [] of String
  getter peak = 0
  getter? stalled = false
  @active = 0
  @arrivals = Hash(Int32, Int32).new(0)
  @gates = Hash(String, Channel(Nil)).new { |hash, key| hash[key] = Channel(Nil).new(1) }

  def initialize(@reverse : Bool)
  end

  def handle(context : HTTP::Server::Context) : Nil
    path = context.request.path
    @counts[path] += 1
    group = ROOTS.includes?(path) ? ROOTS : LEAVES
    order = @reverse ? group.reverse : group
    @active += 1
    @peak = Math.max(@peak, @active)
    @arrivals[group.size] += 1
    @gates[order.first].send(nil) if @arrivals[group.size] == group.size
    select
    when @gates[path].receive
    when timeout(2.seconds)
      @stalled = true # Escape a broken concurrency implementation, not a timing assertion
    end
    context.response.print(body(path))
    context.response.close
    @completions << path
    if next_path = order[order.index!(path) + 1]?
      @gates[next_path].send(nil)
    end
  ensure
    @active -= 1
  end

  private def body(path : String) : String
    if path == ROOTS[0]
      children = [ROOTS[0]] + LEAVES.first(4) + [LEAVES[0]]
      xml(["/root-z"], children)
    elsif path == ROOTS[1]
      children = [LEAVES[0], ROOTS[1]] + LEAVES.last(4)
      xml(["/root-a", "/root-z"], children)
    else
      pages = ["/root-a", "/shared", "/shared"] + (0...12).map { |i| "/page#{path}/#{11 - i}" }
      xml(pages, [ROOTS[0], path, LEAVES[0]])
    end
  end

  private def xml(pages : Array(String), children : Array(String)) : String
    String.build do |io|
      io << "<root xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'><url><loc> </loc></url>"
      pages.each { |path| io << "<url><loc>#{@base}#{path}</loc></url>" }
      children.each { |path| io << "<sitemap><loc>#{@base}#{path}</loc></sitemap>" }
      io << "</root>"
    end
  end
end

private def crawl_sitemaps(base : String, seeds : Array(String), budget : Nokizaru::Crawler::Budget)
  pool = Nokizaru::Http::Pool.new
  begin
    fetcher = Nokizaru::Crawler::Fetcher.new(pool)
    counts = Nokizaru::Crawler::Surface.new(0, 0, 0, seeds.size, 0, 0)
    Nokizaru::Crawler::Sitemaps.new(fetcher, HTTP::Headers.new, budget, counts).crawl(seeds, "#{base}/")
  ensure
    pool.shutdown
  end
end

describe Nokizaru::Crawler::Sitemaps do
  it "selects the same BFS and document-order prefix when capped responses finish in reverse" do
    [false, true].each do |reverse|
      fixture = OrderedSitemapFixture.new(reverse)
      HttpTestServer.with_server(->(context : HTTP::Server::Context) { fixture.handle(context) }) do |base|
        fixture.base = base
        budget = Nokizaru::Crawler::Budget.new
        budget.max_sitemap_urls = 7
        budget.max_sitemap_links = 6
        seeds = OrderedSitemapFixture::ROOTS.map { |path| "#{base}#{path}" }
        pages, sitemaps = crawl_sitemaps(base, seeds + seeds, budget)
        expected = ["/root-z", "/root-a", "/shared"] + (0...4).map { |i| "/page/z3.xml/#{11 - i}" }
        pages.should eq(expected.map { |path| "#{base}#{path}" })
        expected_maps = OrderedSitemapFixture::ROOTS + OrderedSitemapFixture::LEAVES.first(4)
        sitemaps.should eq(expected_maps.map { |path| "#{base}#{path}" })
        fixture.stalled?.should be_false
        fixture.peak.should eq(Nokizaru::Crawler::MAX_FETCH_WORKERS)
        paths = OrderedSitemapFixture::ROOTS + OrderedSitemapFixture::LEAVES
        fixture.counts.should eq(paths.to_h { |path| {path, 1} })
        completed = reverse ? OrderedSitemapFixture::ROOTS.reverse + OrderedSitemapFixture::LEAVES.reverse : paths
        fixture.completions.should eq(completed)
      end
    end
  end

  it "keeps exported and scoped child caps independent and schedules cycle URLs at most once" do
    base_url = ""
    requests = Hash(String, Int32).new(0)
    handler = ->(context : HTTP::Server::Context) do
      path = context.request.path
      requests[path] += 1
      context.response.print(String.build do |io|
        io << "<root>"
        if path == "/root.xml"
          io << "<sitemap><loc>#{base_url.sub("127.0.0.1", "localhost")}/outside.xml</loc></sitemap>"
          ["/bad.html", "/root.xml", "/a.xml", "/a.xml", "/b.xml", "/c.xml"].each do |child|
            io << "<sitemap><loc>#{base_url}#{child}</loc></sitemap>"
          end
        else
          ["/root.xml", "/a.xml", "/b.xml"].each do |child|
            io << "<sitemap><loc>#{base_url}#{child}</loc></sitemap>"
          end
          ["/shared", "/shared", "/page#{path}"].each do |page|
            io << "<url><loc>#{base_url}#{page}</loc></url>"
          end
        end
        io << "</root>"
      end)
    end
    HttpTestServer.with_server(handler) do |base|
      base_url = base
      budget = Nokizaru::Crawler::Budget.new
      budget.max_sitemaps = 3
      budget.max_sitemap_links = 2
      pages, sitemaps = crawl_sitemaps(base, ["#{base}/root.xml"], budget)
      pages.should eq(["/shared", "/page/a.xml", "/page/b.xml"].map { |path| "#{base}#{path}" })
      sitemaps.should eq(["#{base}/root.xml", "#{base.sub("127.0.0.1", "localhost")}/outside.xml"])
      requests.should eq({"/root.xml" => 1, "/a.xml" => 1, "/b.xml" => 1})
    end
  end
end
