require "../spec_helper"
require "json"
require "file_utils"
require "../../src/nokizaru/exporters/txt"

private def run_with_findings : Nokizaru::RunState
  meta = Nokizaru::Meta.new(
    version: "1.0.0", target: "https://example.com",
    started_at: "2026-08-29T00:00:00Z", ended_at: "2026-08-29T00:01:00Z",
  )
  run = Nokizaru::RunState.new(meta)
  run.findings << Nokizaru::Finding.new(
    id: "x", severity: "high", title: "Open admin",
    source_module: "headers", tags: ["headers"], evidence: "found /admin", recommendation: "lock it down",
  )
  run
end

private def with_tmpdir(&)
  dir = File.tempname("nokizaru-txt-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# The Wayback payload shape mirrors the Ruby export_manager test fixture. The
# typed Wayback result lands in a later phase; at the foundation layer the
# renderer is exercised directly over the JSON payload it will serialize to.
private def wayback_payload : JSON::Any
  JSON.parse(<<-JSON)
    {
      "status": "complete",
      "archive_status": "degraded",
      "review_urls": ["https://example.com/admin"],
      "javascript_urls": ["https://example.com/app.js"],
      "parameter_counts": {"id": 2},
      "urls": ["https://example.com/admin", "https://example.com/ordinary"],
      "url_records": [
        {"url": "https://example.com/ordinary", "source": "wayback", "sources": ["wayback"]}
      ],
      "historical_snapshots": [
        {"timestamp": "20250829000000", "reasons": ["one_year"],
         "snapshot_url": "https://web.archive.org/web/20250829000000/https://example.com/admin"}
      ],
      "changed_snapshots": [
        {"timestamp": "20260829000000", "reasons": ["changed"], "changes": ["content", "status"],
         "snapshot_url": "https://web.archive.org/web/20260829000000/https://example.com/admin"}
      ],
      "source_health": {"cdx": {"status": "timeout", "reason": "timeout", "records": 0}},
      "truncation": {"truncated": true, "limit": 25, "resume_key": "dead-key"}
    }
    JSON
end

describe Nokizaru::Exporters::Txt do
  it "writes meta and findings from the typed tree" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.txt")
      Nokizaru::Exporters::Txt.write(run_with_findings, path)
      output = File.read(path)

      output.should contain("Target: https://example.com")
      output.should contain("Started: 2026-08-29T00:00:00Z")
      output.should contain("Ended: 2026-08-29T00:01:00Z")
      output.should contain("Findings\n========")
      output.should contain("[HIGH] Open admin")
      output.should contain("  Evidence: found /admin")
      output.should contain("  Recommendation: lock it down")
    end
  end

  it "writes the export owner-only" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.txt")
      Nokizaru::Exporters::Txt.write(run_with_findings, path)
      (File.info(path).permissions.value & 0o777).to_s(8).should eq("600")
    end
  end

  it "renders the Wayback payload into readable sections rather than dumping it" do
    io = IO::Memory.new
    Nokizaru::Exporters::Txt.write_modules(io, {"wayback" => wayback_payload})
    output = io.to_s

    output.should contain("Review (1)\n  https://example.com/admin")
    output.should contain("Javascript (1)\n  https://example.com/app.js")
    output.should contain("Parameters: id=2")
    output.should contain("Archive Status: degraded")
    output.should contain("wayback\thttps://example.com/ordinary")
    output.should contain("Historical snapshots (1)\n  20250829000000\tone_year\thttps://web.archive.org/web/")
    output.should contain(
      "State-change snapshots (1)\n  20260829000000\tchanged(content,status)\thttps://web.archive.org/web/"
    )
    output.should contain("Raw URLs (2)\n  https://example.com/admin\n  https://example.com/ordinary")
    output.should_not contain("Truncated:")
    output.should_not contain("dead-key")
    output.should_not contain("review_urls=>")
  end

  it "dumps a non-Wayback module payload as pretty JSON" do
    io = IO::Memory.new
    Nokizaru::Exporters::Txt.write_modules(io, {"headers" => JSON.parse(%({"server": "fixture"}))})
    output = io.to_s

    output.should contain("headers\n=======")
    output.should contain(%("server": "fixture"))
  end
end
