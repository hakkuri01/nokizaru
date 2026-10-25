require "../spec_helper"
require "../support/wayback_transport"

describe Nokizaru::Wayback::Fetcher do
  it "shares one absolute deadline across two retries and backoff" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) do
      clock.advance(1.0)
      wayback_response(503)
    end)
    result = transport.fetcher.get("https://web.archive.org/cdx/search/cdx", clock.instant + 5.seconds)
    result.status.should eq(503)
    transport.requests.map(&.budget).should eq([5.0, 3.75, 2.25])
    clock.sleeps.should eq([0.25, 0.5])
    transport.requests.size.should eq(3)
  end

  it "does not retry transport failures, including timeouts" do
    {Nokizaru::Http::ErrorKind::Timeout, Nokizaru::Http::ErrorKind::Io}.each do |kind|
      clock = WaybackClock.new
      transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { Nokizaru::Http::Result.failure(kind, "failure") })
      transport.fetcher.get("https://archive.org/", clock.instant + 10.seconds).error_kind.should eq(kind)
      transport.requests.size.should eq(1)
      clock.sleeps.should be_empty
    end
  end

  it "does not retry early when numeric or HTTP-date Retry-After cannot fit" do
    {429, 503}.each do |status|
      {"999999", "Thu, 01 Jan 2026 00:00:03 GMT", "2.76"}.each do |header|
        clock = WaybackClock.new
        transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { wayback_response(status, retry_after: header) })
        result = transport.fetcher.get("https://archive.org/", clock.instant + 3.seconds)
        result.status.should eq(status)
        result.headers["Retry-After"].should eq(header)
        transport.requests.map(&.budget).should eq([3.0])
        clock.sleeps.should be_empty
      end
    end
  end

  it "accepts HTTP-date Retry-After and falls back for malformed values" do
    {"Thu, 01 Jan 2026 00:00:01 GMT" => 1.0, "invalid" => 0.25, "-1" => 0.25}.each do |header, delay|
      clock = WaybackClock.new
      calls = 0
      transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) do
        calls += 1
        wayback_response(calls == 1 ? 503 : 200, retry_after: header)
      end)
      transport.fetcher.get("https://archive.org/", clock.instant + 5.seconds).status.should eq(200)
      clock.sleeps.should eq([delay])
    end
  end

  it "waits the full Retry-After when it fits with exactly one useful retry budget" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { wayback_response(429, retry_after: "2.75") })
    transport.fetcher.get("https://archive.org/", clock.instant + 3.seconds).status.should eq(429)
    transport.requests.map(&.budget).should eq([3.0, 0.25])
    clock.sleeps.should eq([2.75])
  end
  it "starts neither calls nor sleeps after expiry, including expiry during a response or backoff" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) do
      clock.advance(1.0)
      wayback_response(503)
    end)
    fetcher = transport.fetcher
    fetcher.get("https://archive.org/", clock.instant).error_kind.timeout?.should be_true
    transport.requests.should be_empty
    fetcher.get("https://archive.org/", clock.instant + 1.seconds).status.should eq(503)
    transport.requests.size.should eq(1)
    clock.sleeps.should be_empty

    late = Nokizaru::Wayback::Fetcher.new(transport.pool, clock: -> { clock.instant },
      sleeper: ->(delay : Time::Span) { clock.sleep(delay + 10.seconds) })
    late.get("https://archive.org/", clock.instant + 3.seconds).error_kind.timeout?.should be_true
    transport.requests.size.should eq(2)
    clock.sleeps.size.should eq(1)
  end

  it "uses the supplied absolute stage deadline without imposing a fresh ten-second cap" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      clock.advance({9.0, request.budget}.min)
      wayback_response(503)
    end)
    transport.fetcher.get("https://archive.org/", clock.instant + 55.seconds).status.should eq(503)
    transport.requests.map(&.budget).should eq([55.0, 45.75, 36.25])
  end
end
