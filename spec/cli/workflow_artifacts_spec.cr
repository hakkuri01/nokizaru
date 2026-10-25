require "../spec_helper"
require "file_utils"
require "../../src/nokizaru/cli/workflow"

private alias Modules = Nokizaru::Modules

# Inject completed collects through the same guarded handoff as execute!
private class ArtifactWorkflow < Nokizaru::CLI::Workflow
  def collect_result(plan : Plan, key : String, result)
    run_module(plan, key, 0.0) { result }
  end

  def failed_collect(plan : Plan)
    run_module(plan, "dns", 0.0) { Modules::DnsEnumeration::Result.from_json("invalid") }
  end
end

private def with_artifact_export(&)
  directory = File.tempname("nok-artifacts")
  opts = Nokizaru::CLI::Options.new
  opts.target = "https://example.com"
  opts.full = true
  opts.export = true
  opts.formats = "json"
  opts.export_dir = directory
  opts.export_basename = "scan"
  resolve = ->(_host : String) { "127.0.0.1".as(String?) }
  workflow = ArtifactWorkflow.new(opts, Nokizaru::Settings.new, resolve)
  Nokizaru::UI.output = IO::Memory.new
  plan = workflow.plan!
  yield workflow, plan
  workflow.finalize!(plan)
  JSON.parse(File.read(File.join(directory, "scan.json")))
ensure
  Nokizaru::UI.output = STDOUT
  FileUtils.rm_rf(directory) if directory
end

private def artifact_crawl : Modules::Crawler::Result
  target = Nokizaru::Crawler::Target.new("https://example.com", "https://example.com", false, "", "")
  result = Modules::Crawler::Result.new(target, "ok")
  result.stats = Nokizaru::Crawler::Stats.new(total_urls: ["https://example.com/admin", "https://cdn.example.com/app.js"])
  result.high_signal_urls = ["https://example.com/admin"]
  result
end

private def artifact_directory : Modules::DirectoryEnum::Result
  target = Nokizaru::DirRec::Target.new("https://example.com", "https://example.com", false, "")
  result = Modules::DirectoryEnum::Result.new(target)
  result.found = ["https://example.com/noise"]
  result.confirmed_found = ["https://example.com/confirmed-only"]
  result.prioritized_found = ["https://example.com/admin", "https://example.com/config"]
  result.high_signal_found = ["https://example.com/config"]
  result
end

private def artifact_wayback : Modules::Wayback::Result
  result = Modules::Wayback::Result.new
  result.urls = ["https://example.com/admin", "https://example.com/api/app.js?id=1"]
  result.high_signal_urls = [result.urls.last]
  result.javascript_urls = [result.urls.last]
  result.api_urls = [result.urls.last]
  result.interesting_path_urls = [result.urls.first]
  result.interesting_parameter_urls = [result.urls.last]
  result.sensitive_file_urls = ["https://example.com/.env"]
  result.review_urls = [result.urls.last]
  snapshot = Nokizaru::Wayback::Snapshot.new(result.urls.first, "https://web.archive.org/web/20200101000000/https://example.com/admin", "20200101000000", [] of String)
  changed = Nokizaru::Wayback::Snapshot.new(result.urls.last, "https://web.archive.org/web/20210101000000/https://example.com/api/app.js?id=1", "20210101000000", [] of String)
  result.historical_snapshots = [snapshot]
  result.changed_snapshots = [snapshot, changed]
  result
end

private def artifact_ports : Modules::PortScan::Result
  ports = [80, 443, 6379].map do |port|
    record = Nokizaru::Portscan::PortRecord.build("127.0.0.1", Nokizaru::Portscan::OpenPort.new(port, "service", 1.0))
    record.downgrade_tarpit!
    record
  end
  Modules::PortScan::Result.new(ports.map(&.label), ports, 3, "tarpit", "high")
end

describe Nokizaru::CLI::Workflow do
  it "exports artifact values from every successful module through the guarded handoff" do
    crawl = artifact_crawl
    directory = artifact_directory
    wayback = artifact_wayback
    json = with_artifact_export do |workflow, plan|
      workflow.collect_result(plan, "dns", Modules::DnsEnumeration::Result.new({"TXT" => ["v=spf1 -all", "v=spf1 -all"], "DMARC" => ["not a TXT artifact"]}))
      health = Modules::Subdomains::Health.new([] of Modules::Subdomains::ProviderHealth, {} of String => Int32)
      workflow.collect_result(plan, "sub", Modules::Subdomains::Result.new(["a.example.com", "b.example.com"], health))
      technology = Modules::Arch::Technology.new("nginx", "1", ["Web servers"])
      workflow.collect_result(plan, "arch", Modules::Arch::Result.ok([technology, technology]))
      workflow.collect_result(plan, "ps", artifact_ports)
      workflow.collect_result(plan, "crawl", crawl)
      workflow.collect_result(plan, "dir", directory)
      workflow.collect_result(plan, "wayback", wayback)
    end
    expected = {
      "dns_txt"                            => ["v=spf1 -all"],
      "subdomains"                         => ["a.example.com", "b.example.com"],
      "technologies"                       => ["nginx"],
      "open_ports"                         => ["80", "443"],
      "urls"                               => ["https://example.com/admin", "https://cdn.example.com/app.js", "https://example.com/api/app.js?id=1"],
      "high_signal_urls"                   => ["https://example.com/admin"],
      "paths"                              => directory.prioritized_found,
      "prioritized_paths"                  => directory.prioritized_found,
      "high_signal_paths"                  => directory.high_signal_found,
      "wayback_urls"                       => wayback.urls,
      "wayback_high_signal_urls"           => wayback.high_signal_urls,
      "wayback_snapshot_urls"              => [wayback.historical_snapshots.first.snapshot_url, wayback.changed_snapshots.last.snapshot_url],
      "wayback_javascript_urls"            => wayback.javascript_urls,
      "wayback_api_urls"                   => wayback.api_urls,
      "wayback_interesting_path_urls"      => wayback.interesting_path_urls,
      "wayback_interesting_parameter_urls" => wayback.interesting_parameter_urls,
      "wayback_sensitive_file_urls"        => wayback.sensitive_file_urls,
      "wayback_review_urls"                => wayback.review_urls,
    }
    json["artifacts"].should eq(JSON.parse(expected.to_json))
    json["modules"]["portscan"]["ports"][2]["confidence"].as_s.should eq("low")
    json["modules"].as_h.size.should eq(7)
  end

  it "keeps mandatory empty keys but omits empty optional artifact categories" do
    json = with_artifact_export do |workflow, plan|
      workflow.collect_result(plan, "dns", Modules::DnsEnumeration::Result.new({} of String => Array(String)))
      workflow.collect_result(plan, "arch", Modules::Arch::Result.ok([] of Modules::Arch::Technology))
      workflow.collect_result(plan, "ps", Modules::PortScan::Result.new([] of String, [] of Nokizaru::Portscan::PortRecord, 0, "normal", "high"))
      health = Modules::Subdomains::Health.new([] of Modules::Subdomains::ProviderHealth, {} of String => Int32)
      workflow.collect_result(plan, "sub", Modules::Subdomains::Result.new([] of String, health))
      directory = artifact_directory
      directory.prioritized_found.clear
      directory.high_signal_found.clear
      workflow.collect_result(plan, "dir", directory)
      crawl = artifact_crawl
      crawl.stats = Nokizaru::Crawler::Stats.new(total_urls: [] of String)
      crawl.high_signal_urls = [] of String
      workflow.collect_result(plan, "crawl", crawl)
      workflow.collect_result(plan, "wayback", Modules::Wayback::Result.new)
    end
    json["artifacts"].should eq(JSON.parse(%({"dns_txt":[],"technologies":[],"open_ports":[],"subdomains":[],"paths":[],"urls":[]})))
  end

  it "does not invent artifact keys for skipped, failed, or disabled modules" do
    json = with_artifact_export do |workflow, plan|
      workflow.failed_collect(plan).should be_nil
      plan.state.modules.dns.should be_nil
      workflow.collect_result(plan, "dns", Modules::DnsEnumeration::Result.new({} of String => Array(String), "DNS Records Not Found"))
      workflow.collect_result(plan, "arch", Modules::Arch::Result.skipped)
      workflow.collect_result(plan, "arch", Modules::Arch::Result.error)
      crawl = artifact_crawl
      crawl.stats = Nokizaru::Crawler::Stats.new
      crawl.high_signal_urls = nil
      workflow.collect_result(plan, "crawl", crawl)
      plan.enabled.delete("sub")
      health = Modules::Subdomains::Health.new([] of Modules::Subdomains::ProviderHealth, {} of String => Int32)
      workflow.collect_result(plan, "sub", Modules::Subdomains::Result.new(["disabled.example.com"], health)).should be_nil
    end
    json["artifacts"].as_h.should be_empty
    json["modules"].as_h.has_key?("subdomains").should be_false
  end

  it "sanitizes artifact text before export and deduplicates the safe values" do
    json = with_artifact_export do |workflow, plan|
      txt = ["\e[31mv=spf1\e[0m\u0000\u0085\u202E -all", "v=spf1 -all", "line\n\tvalue", "\e]52;c;secret\av=spf1 -all"]
      workflow.collect_result(plan, "dns", Modules::DnsEnumeration::Result.new({"TXT" => txt}))
    end
    json["artifacts"]["dns_txt"].as_a.map(&.as_s).should eq(["v=spf1 -all", "line    value"])
  end
end
