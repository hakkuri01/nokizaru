require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/modules/wayback"
require "../../src/nokizaru/context"

private CDX_JSON = %q([["timestamp","original","mimetype","statuscode","digest"],["20230101000000","http://example.com/admin","text/html","200","AAA"],["20230601000000","http://example.com/api/v1/users","application/json","200","BBB"]])

describe Nokizaru::Modules::Wayback do
  it "overlaps all four same-origin CDX requests on real worker-owned clients" do
    entered = Channel(Nil).new(4)
    release = Channel(Nil).new
    active = 0
    peak = 0
    requests = 0
    handler = ->(context : ::HTTP::Server::Context) do
      active += 1
      peak = {peak, active}.max
      requests += 1
      entered.send(nil)
      release.receive
      context.response.print(CDX_JSON)
      active -= 1
    end
    HttpTestServer.with_server(handler) do |base|
      spawn do
        4.times { entered.receive }
        4.times { release.send(nil) }
      end
      result = Nokizaru::Modules::Wayback.collect(
        "http://example.com/", Nokizaru::Http::Pool.new, "#{base}/cdx", "#{base}/available", 5.0)
      result.cdx_status.should eq("complete")
      peak.should eq(4)
      requests.should eq(4)
      active.should eq(0)
    end
  end

  it "assembles the payload from CDX history with triage and health" do
    handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/cdx"       then context.response.print(CDX_JSON)
      when "/available" then context.response.print(%q({"archived_snapshots":{}}))
      else                   context.response.status_code = 404
      end
    end

    HttpTestServer.with_server(handler) do |base|
      result = Nokizaru::Modules::Wayback.collect(
        "http://example.com/", Nokizaru::Http::Pool.new, "#{base}/cdx", "#{base}/available", 5.0
      )

      result.schema_version.should eq(4)
      result.status.should eq("complete")
      result.cdx_status.should eq("complete")
      result.archive_status.should eq("healthy")
      result.urls.should contain("http://example.com/admin")
      result.urls.should contain("http://example.com/api/v1/users")
      result.url_records.size.should eq(2)
      result.source_health["cdx"].status.should eq("found")
      result.interesting_path_urls.should contain("http://example.com/admin")
      result.api_urls.should contain("http://example.com/api/v1/users")
      result.high_signal_urls.should eq(result.review_urls)

      json = JSON.parse(result.to_json)
      json.as_h.has_key?("error").should be_true
      json["error"].raw.should be_nil
    end
  end

  it "returns a failed payload for an unusable target and stores it on the run" do
    result = Nokizaru::Modules::Wayback.collect(
      "notaurl", Nokizaru::Http::Pool.new, "http://127.0.0.1:1/cdx", "http://127.0.0.1:1/available", 2.0
    )

    result.status.should eq("failed")
    result.archive_status.should eq("degraded")
    result.cdx_status.should eq("archive_degraded")
    result.source_health["cdx"].status.should eq("failed")
    result.availability_reason.should eq("exception")

    run = Nokizaru::RunState.new(Nokizaru::Meta.new(version: "1.0.0", target: "x", started_at: "t"))
    run.modules.wayback = result
    run.modules.wayback.should_not be_nil
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

describe "Nokizaru::Modules::Wayback.present" do
  it "renders availability, archive status, CDX retrieval, and snapshot lists" do
    result = Nokizaru::Wayback::Result.new
    result.status = "complete"
    result.cdx_status = "complete"
    result.archive_status = "healthy"
    result.availability = "available"
    result.urls = ["http://example.com/admin"]
    result.source_health = {
      "cdx"          => Nokizaru::Wayback::SourceHealth.new("found", 1),
      "availability" => Nokizaru::Wayback::SourceHealth.new("found"),
    }
    result.historical_snapshots = [
      Nokizaru::Wayback::Snapshot.new(
        url: "http://example.com/admin",
        snapshot_url: "https://web.archive.org/web/20230101000000/http://example.com/admin",
        timestamp: "20230101000000", signal: ["interesting_path"], reasons: ["three_months"]),
    ]
    result.changed_snapshots = [
      Nokizaru::Wayback::Snapshot.new(
        url: "http://example.com/api", snapshot_url: "https://web.archive.org/web/20230601000000/http://example.com/api",
        timestamp: "20230601000000", signal: [] of String, reasons: ["changed"], changes: ["content", "status"]),
    ]

    text = present_capture { Nokizaru::Modules::Wayback.present(result) }

    text.should contain("Available")
    text.should contain("Healthy")
    text.should contain("Fetching URLs from CDX")
    text.should contain("Wayback Historical Snapshots")
    text.should contain("Three months")
    text.should contain("Changed (content, status)")
  end

  it "renders an empty-CDX label and the manual review pivots when no URLs were found" do
    result = Nokizaru::Wayback::Result.new
    result.status = "failed"
    result.cdx_status = "archive_degraded"
    result.archive_status = "degraded"
    result.availability = "unknown"
    result.source_health = {
      "cdx"          => Nokizaru::Wayback::SourceHealth.new("failed", 0, "exception"),
      "availability" => Nokizaru::Wayback::SourceHealth.new("skipped", 0, "exception"),
    }
    result.manual_pivots = {
      "calendar_url"           => "https://web.archive.org/web/*/http://example.com",
      "changes_url"            => "https://web.archive.org/web/changes/http://example.com",
      "availability_query_url" => "https://archive.org/wayback/available?url=http://example.com",
      "cdx_query_url"          => "https://web.archive.org/cdx/search/cdx?url=http://example.com",
    }

    text = present_capture { Nokizaru::Modules::Wayback.present(result) }

    text.should contain("Degraded or rate-limited")
    text.should contain("Archive degraded (Exception)")
    text.should contain("Wayback Manual Review Links")
    text.should contain("Calendar")
    text.should contain("https://web.archive.org/web/*/http://example.com")
  end
end
