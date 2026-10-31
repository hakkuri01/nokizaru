require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/engine"

private class CrawlBarrier
  getter peak = 0
  getter? stalled = false
  @active = 0
  @arrivals = 0
  @gate = Channel(Nil).new(Nokizaru::Crawler::MAX_FETCH_WORKERS)

  def hold(&) : Nil
    @active += 1
    @arrivals += 1
    @peak = Math.max(@peak, @active)
    cap = Nokizaru::Crawler::MAX_FETCH_WORKERS
    cap.times { @gate.send(nil) } if @arrivals % cap == 0
    select
    when @gate.receive
    when timeout(2.seconds)
      @stalled = true # A failure escape, not a timing assertion
    end
    yield
  ensure
    @active -= 1
  end
end

private class CrawlSockets
  getter counts = Hash(String, Int32).new(0)
  getter accepted = 0
  @closed = Channel(Nil).new(64)
  @sockets = [] of TCPSocket

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    spawn do
      while socket = @server.accept?
        @accepted += 1
        @sockets << socket
        spawn handle(socket)
      end
    end
  end

  def base : String
    "http://127.0.0.1:#{@server.local_address.port}"
  end

  def wait_closed(count : Int32) : Nil
    count.times do
      select
      when @closed.receive
      when timeout(3.seconds)
        raise "crawler connection was not closed"
      end
    end
  end

  def close : Nil
    @server.close
    @sockets.each(&.close)
  end

  private def handle(socket : TCPSocket) : Nil
    while request = HTTP::Request.from_io(socket)
      break unless request.is_a?(HTTP::Request)

      @counts[request.path] += 1
      break if request.path == "/broken"

      if request.path == "/timeout"
        socket << "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n"
        socket.flush
        socket.read_byte
        break
      end
      headers = HTTP::Headers.new
      headers["Connection"] = "close" if request.path == "/fresh"
      HTTP::Client::Response.new(200, headers: headers, body: "ok").to_io(socket)
      socket.flush
      break if request.path == "/fresh"
    end
  rescue IO::Error
  ensure
    socket.close
    @closed.send(nil)
  end
end

describe Nokizaru::Crawler::Concurrency do
  it "overlaps same-origin sitemap and JS requests within the worker cap without refetching the seed" do
    cap = Nokizaru::Crawler::MAX_FETCH_WORKERS
    counts = Hash(String, Int32).new(0)
    peers = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
    barrier = CrawlBarrier.new
    base_url = ""
    handler = ->(context : HTTP::Server::Context) do
      path = context.request.path
      counts[path] += 1
      case path
      when "/"
        context.response.print((0...cap * 2).join { |i| %(<script src="/js/#{i}.js"></script>) })
      when "/robots.txt"
        context.response.print("Sitemap: /sitemap.xml\n")
      when "/sitemap.xml"
        children = (0...cap * 2).join { |i| "<sitemap><loc>#{base_url}/maps/#{i}.xml</loc></sitemap>" }
        context.response.print("<sitemapindex>#{children}</sitemapindex>")
      else
        group = path.starts_with?("/js/") ? "js" : "maps"
        peers[group] << context.request.remote_address.to_s
        barrier.hold do
          if group == "js"
            context.response.print(%("#{base_url}/api#{path}"))
          else
            context.response.print("<urlset><url><loc>#{base_url}/page#{path}</loc></url></urlset>")
          end
        end
      end
    end
    HttpTestServer.with_server(handler) do |base|
      base_url = base
      pool = Nokizaru::Http::Pool.new
      begin
        target = "#{base}/"
        profile = Nokizaru::TargetIntel.profile(target, nil)
        result = Nokizaru::Crawler::Engine.new(pool, HTTP::Headers.new).run(target, profile)
        result.urls_inside_sitemap.size.should eq(cap * 2)
        result.urls_inside_js.size.should eq(cap * 2)
        barrier.stalled?.should be_false
        barrier.peak.should eq(cap)
        peers.values.each(&.size.should eq(cap))
        counts.size.should eq(3 + cap * 4)
        counts.values.each(&.should eq(1))
      ensure
        pool.shutdown
      end
    end
  end

  it "reuses a bounded number of connections and closes every worker socket" do
    server = CrawlSockets.new
    cap = Nokizaru::Crawler::MAX_FETCH_WORKERS
    begin
      urls = Array.new(cap * 3) { |i| "#{server.base}/ok?i=#{i}" }
      Nokizaru::Crawler::Concurrency.each_concurrently(urls, Nokizaru::Http::Pool.new) do |url, fetcher|
        fetcher.get(url, HTTP::Headers.new, "probe").body.should eq("ok")
      end
      server.accepted.should eq(cap)
      server.counts["/ok"].should eq(urls.size)
      server.wait_closed(cap)
    ensure
      server.close
    end
  end

  it "closes sockets and joins workers before propagating a block exception" do
    server = CrawlSockets.new
    begin
      expect_raises(Exception, "probe failure") do
        Nokizaru::Crawler::Concurrency.each_concurrently(["#{server.base}/ok"], Nokizaru::Http::Pool.new) do |url, fetcher|
          fetcher.get(url, HTTP::Headers.new, "probe").success?.should be_true
          raise "probe failure"
        end
      end
      server.wait_closed(1)
      Nokizaru::Crawler::Concurrency.each_concurrently(["#{server.base}/ok"], Nokizaru::Http::Pool.new) do |url, fetcher|
        fetcher.get(url, HTTP::Headers.new, "probe").success?.should be_true
      end
      server.wait_closed(1)
      server.counts["/ok"].should eq(2)
    ensure
      server.close
    end
  end

  it "closes the previous origin before connecting to another one" do
    first = CrawlSockets.new
    second = CrawlSockets.new
    begin
      Nokizaru::Crawler::Concurrency.each_concurrently(["#{first.base}/ok"], Nokizaru::Http::Pool.new) do |url, fetcher|
        fetcher.get(url, HTTP::Headers.new, "probe").body.should eq("ok")
        fetcher.get("#{second.base}/ok", HTTP::Headers.new, "probe").body.should eq("ok")
        first.wait_closed(1)
        fetcher.get(url, HTTP::Headers.new, "probe").body.should eq("ok")
        second.wait_closed(1)
      end
      first.wait_closed(1)
      first.accepted.should eq(2)
      second.accepted.should eq(1)
    ensure
      first.close
      second.close
    end
  end

  it "returns connections after transport errors and deadlines so later requests succeed" do
    server = CrawlSockets.new
    begin
      Nokizaru::Crawler::Concurrency.each_concurrently(["#{server.base}/fresh"], Nokizaru::Http::Pool.new) do |url, fetcher|
        ["broken", "timeout"].each do |path|
          result = fetcher.get("#{server.base}/#{path}", HTTP::Headers.new, "probe", timeout: 0.02)
          result.error?.should be_true
          result.error_kind.should eq(Nokizaru::Http::ErrorKind::Timeout) if path == "timeout"
          fetcher.get(url, HTTP::Headers.new, "probe").body.should eq("ok")
        end
      end
      attempts = Nokizaru::Crawler::MAX_HTTP_RETRIES + 1
      server.counts.should eq({"/broken" => attempts, "/timeout" => attempts, "/fresh" => 2})
      server.wait_closed(server.accepted)
    ensure
      server.close
    end
  end
end
