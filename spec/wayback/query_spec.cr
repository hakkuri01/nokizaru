require "../spec_helper"
require "../support/wayback_transport"

describe Nokizaru::Wayback::Query do
  it "runs exactly four healthy requests concurrently on distinct owned pools and merges by slot" do
    clock = WaybackClock.new
    entered = Channel(WaybackRequest).new(4)
    release = Array.new(4) { Channel(Nil).new }
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      entered.send(request)
      release[request.worker - 2].receive
      wayback_response(body: wayback_page("/slot#{request.worker}"))
    end)
    spawn do
      requests = Array.new(4) { entered.receive }
      requests.map(&.worker).to_set.size.should eq(4)
      3.downto(0) { |index| release[index].send(nil) }
    end
    result = wayback_query(transport).run("http://example.com/")
    transport.peak.should eq(4)
    transport.requests.size.should eq(4)
    transport.closed.sort.should eq([2, 3, 4, 5])
    result.urls.should eq((2..5).map { |index| "http://example.com/slot#{index}" })
    result.cdx_status.should eq("complete")
    result.source_health["availability"].reason.should eq("not_requested")
    Fiber.yield
    transport.requests.size.should eq(4)
  end

  it "bounds stalled anchors to six seconds and history to its absolute stage deadline without late traffic" do
    clock = WaybackClock.new
    entered = Channel(WaybackRequest).new(4)
    anchors = Channel(Nil).new
    history = Channel(Nil).new
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
        request.budget.should eq(3.0)
        clock.advance(request.budget)
      else
        entered.send(request)
        URI.parse(request.url).query_params["collapse"]? ? anchors.receive : history.receive
      end
      Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "timeout")
    end)
    started = clock.instant
    spawn do
      requests = Array.new(4) { entered.receive }
      requests.map(&.budget).should eq([6.0, 6.0, 6.0, 55.0])
      clock.advance(6.0)
      3.times { anchors.send(nil) }
      clock.advance(49.0)
      history.send(nil)
    end
    result = wayback_query(transport).run("http://example.com/")
    (clock.instant - started).total_seconds.should eq(58.0)
    result.cdx_status.should eq("timeout")
    result.archive_status.should eq("degraded")
    result.timed_out?.should be_true
    transport.requests.size.should eq(5)
    transport.closed.size.should eq(4)
    clock.sleeps.should be_empty
    Fiber.yield
    transport.requests.size.should eq(5)
  end

  it "makes no calls when the total budget is smaller than the processing reserve" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { wayback_response(503) })
    result = wayback_query(transport, 1.0).run("http://example.com/")
    result.cdx_status.should eq("timeout")
    result.availability_reason.should eq("timeout")
    transport.requests.should be_empty
    clock.sleeps.should be_empty
  end

  it "shrinks availability to the remaining time minus the two-second reserve" do
    clock = WaybackClock.new
    started = clock.instant
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
        request.budget.should eq(0.5)
        clock.advance(request.budget)
        Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "timeout")
      else
        clock.advance(2.5) unless URI.parse(request.url).query_params["collapse"]?
        wayback_response(404)
      end
    end)
    result = wayback_query(transport, 5.0).run("http://example.com/")
    result.availability_reason.should eq("timeout")
    (clock.instant - started).total_seconds.should eq(3.0)
    transport.requests.map(&.budget).should eq([0.5, 0.5, 0.5, 3.0, 0.5])
    clock.sleeps.should be_empty
  end

  it "keeps cursor pages sequential, does not refetch the first page, and retains records on expiry" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      params = URI.parse(request.url).query_params
      if params["collapse"]?
        wayback_response(body: [Nokizaru::Wayback::Cdx::FIELDS].to_json)
      elsif params["resumeKey"]? == "next"
        request.budget.should eq(7.75)
        clock.advance(request.budget)
        wayback_response(body: wayback_page("/second", "last"))
      else
        wayback_response(body: wayback_page("/first", "next"))
      end
    end)
    result = wayback_query(transport, 10.0).run("http://example.com/")
    result.urls.should eq(["http://example.com/first", "http://example.com/second"])
    result.cdx_status.should eq("partial_timeout")
    result.source_health["availability"].reason.should eq("not_requested")
    transport.requests.size.should eq(5)
    clock.sleeps.should eq([0.25])
    transport.requests.last.url.should contain("resumeKey=next")
    Fiber.yield
    transport.requests.size.should eq(5)
  end

  it "retains recorded CDX captures and a changed snapshot when history takes over ten seconds then times out" do
    clock = WaybackClock.new
    body = [Nokizaru::Wayback::Cdx::FIELDS,
            ["20041015171944", "http://example.com/", "text/html", "200", "EF7YLJGKQUMLJFP3F7A7LBALC65T5W2O"],
            ["20121207181944", "http://example.com/", "unk", "302", "3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ"],
            [] of String, ["next"]].to_json
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      params = URI.parse(request.url).query_params
      if params["collapse"]?
        wayback_response(body: [Nokizaru::Wayback::Cdx::FIELDS].to_json)
      elsif params["resumeKey"]?
        request.budget.should eq(42.75)
        clock.advance(request.budget)
        Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "timeout")
      else
        request.budget.should eq(55.0)
        clock.advance(12.0)
        wayback_response(body: body)
      end
    end)
    result = wayback_query(transport).run("http://example.com/")
    result.cdx_status.should eq("partial_timeout")
    result.cdx_reasons.should eq(["timeout"])
    result.urls.should eq(["http://example.com/"])
    result.changed_snapshots.size.should eq(1)
    result.changed_snapshots.first.timestamp.should eq("20121207181944")
    result.changed_snapshots.first.previous_timestamp.should eq("20041015171944")
    result.source_health["availability"].reason.should eq("not_requested")
    transport.requests.size.should eq(5)
  end

  it "stops repeated cursors and retains records without availability traffic" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { wayback_response(body: wayback_page("/admin", "same")) })
    result = wayback_query(transport).run("http://example.com/")
    result.cdx_reasons.should contain("repeated_resume_key")
    result.urls.should eq(["http://example.com/admin"])
    transport.requests.size.should eq(5)
  end

  it "does not request availability for a healthy empty CDX response" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(_request : WaybackRequest) { wayback_response(body: [Nokizaru::Wayback::Cdx::FIELDS].to_json) })
    result = wayback_query(transport).run("http://example.com/")
    result.cdx_status.should eq("not_found")
    result.archive_status.should eq("healthy")
    transport.requests.size.should eq(4)
  end

  it "does not confuse a clean empty history with clean CDX when an anchor failed" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
        wayback_response(body: %q({"archived_snapshots":{}}))
      elsif URI.parse(request.url).query_params["collapse"]?
        wayback_response(404)
      else
        wayback_response(body: [Nokizaru::Wayback::Cdx::FIELDS].to_json)
      end
    end)
    result = wayback_query(transport).run("http://example.com/")
    result.cdx_status.should eq("partial_failure")
    result.cdx_reasons.should eq(["http_404"])
    result.source_health["availability"].status.should eq("empty")
    result.archive_status.should eq("degraded")
    transport.requests.size.should eq(5)
  end

  it "uses availability only for failed empty CDX and preserves its source health" do
    clock = WaybackClock.new
    transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
      if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
        wayback_response(body: %q({"archived_snapshots":{"closest":{"url":"https://web.archive.org/web/20230101000000/http://example.com/admin","timestamp":"20230101000000","status":"200"}}}))
      else
        wayback_response(404)
      end
    end)
    result = wayback_query(transport).run("http://example.com/")
    result.cdx_status.should eq("fallback")
    result.source_health["cdx"].status.should eq("failed")
    result.source_health["availability"].status.should eq("found")
    result.urls.should eq(["http://example.com/admin"])
    transport.requests.size.should eq(5)
  end

  it "preserves rate-limit and service failure reasons when Retry-After does not fit" do
    {429 => "rate_limited", 503 => "service_unavailable"}.each do |status, reason|
      clock = WaybackClock.new
      transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
        if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
          wayback_response(body: %q({"archived_snapshots":{}}))
        else
          wayback_response(status, retry_after: "999999")
        end
      end)
      result = wayback_query(transport).run("http://example.com/")
      result.cdx_reasons.should eq([reason])
      result.source_health["cdx"].reason.should eq(reason)
      result.cdx_status.should eq(status == 429 ? "rate_limited" : "partial_failure")
      result.source_health["availability"].status.should eq("empty")
      transport.requests.size.should eq(5)
      clock.sleeps.should be_empty
    end
  end
  it "reports a rejected availability snapshot as invalid rather than found" do
    {"https://web.archive.org/web/20230101000000/http://www.example.com/", "https://outside.test/"}.each do |url|
      clock = WaybackClock.new
      transport = WaybackTransport.new(clock, ->(request : WaybackRequest) do
        if request.url.starts_with?(Nokizaru::Wayback::AVAIL_URL)
          wayback_response(body: {"archived_snapshots" => {"closest" => {"url" => url}}}.to_json)
        else
          wayback_response(404)
        end
      end)
      result = wayback_query(transport).run("http://example.com/")
      result.urls.should be_empty
      result.cdx_status.should eq("partial_failure")
      result.source_health["availability"].status.should eq("failed")
      result.source_health["availability"].records.should eq(0)
      result.source_health["availability"].reason.should eq("invalid_snapshot")
      transport.requests.size.should eq(5)
    end
  end
end
