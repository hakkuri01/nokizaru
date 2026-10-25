require "../spec_helper"
require "file_utils"
require "../../src/nokizaru/cli/workflow"

private alias Options = Nokizaru::CLI::Options
private alias Workflow = Nokizaru::CLI::Workflow

private class OutcomeWorkflow < Workflow
  def collect_error(plan : Plan, key : String, error : Exception)
    collect = Proc(Nokizaru::Modules::DnsEnumeration::Result).new { raise error }
    run_module(plan, key, 0.0, &collect)
  end

  def architecture(plan : Plan, pool : Nokizaru::Http::Pool)
    run_arch(plan, pool)
  end
end

private class ArchitecturePool < Nokizaru::Http::Pool
  getter requests = [] of {String, HTTP::Headers}

  def get(url : String, options : Nokizaru::Http::Options = Nokizaru::Http::Options.new) : Nokizaru::Http::Result
    @requests << {url, options.headers}
    Nokizaru::Http::Result.ok(200, HTTP::Headers.new, %({"technologies":[{"name":"nginx"}]}), false)
  end
end

private def with_outcome_export(options : Options, &)
  directory = File.tempname("nok-outcomes")
  previous = {"XDG_DATA_HOME" => ENV["XDG_DATA_HOME"]?, "NK_WAPPALYZER_KEY" => ENV["NK_WAPPALYZER_KEY"]?}
  ENV["XDG_DATA_HOME"] = File.join(directory, "data")
  ENV.delete("NK_WAPPALYZER_KEY")
  options.target ||= "https://example.com"
  options.export = true
  options.formats = "json,txt,html"
  options.export_dir = File.join(directory, "exports")
  options.export_basename = "scan"
  workflow = OutcomeWorkflow.new(options, Nokizaru::Settings.new, ->(_host : String) { nil.as(String?) })
  output = IO::Memory.new
  Nokizaru::UI.output = output
  plan = workflow.plan!
  yield workflow, plan
  workflow.finalize!(plan)
  reports = %w[json txt html].to_h do |format|
    {format, File.read(File.join(directory, "exports", "scan.#{format}"))}
  end
  reports["log"] = File.exists?(Nokizaru::Paths.log_file) ? File.read(Nokizaru::Paths.log_file) : ""
  reports["terminal"] = output.to_s
  File.exists?(Nokizaru::Paths.keys_file).should be_false
  reports
ensure
  Nokizaru::UI.output = STDOUT
  previous.try(&.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) })
  FileUtils.rm_rf(directory) if directory
end

describe Nokizaru::CLI::Workflow do
  it "passes an environment-only architecture key to the transport without persisting it" do
    options = Options.new
    options.modules << "arch"
    options.target = "https://example.com/path?token=target-query#fragment"
    reports = with_outcome_export(options) do |workflow, plan|
      ENV["NK_WAPPALYZER_KEY"] = "env-only-wappalyzer-credential"
      pool = ArchitecturePool.new
      workflow.architecture(plan, pool)
      pool.requests.size.should eq(2)
      page = pool.requests.find! { |(url, _)| !url.includes?("wappalyzer") }
      wapp = pool.requests.find! { |(url, _)| url.includes?("wappalyzer") }
      page[1]["x-api-key"]?.should be_nil # the page fetch never carries the key
      page[0].should eq("https://example.com/path")
      wapp[1]["x-api-key"].should eq("env-only-wappalyzer-credential")
      wapp[0].should eq(Nokizaru::Modules::Arch.request_url("https://example.com/path"))
      plan.state.modules.arch.not_nil!.status.should eq("ok")
    end
    json = JSON.parse(reports["json"])
    json["modules"]["architecture_fingerprinting"]["technologies"][0]["name"].as_s.should eq("nginx")
    json["artifacts"]["technologies"].as_a.map(&.as_s).should eq(["nginx"])
    reports.each_value { |text| text.should_not contain("env-only-wappalyzer-credential") }
  end

  it "exports distinct failures and deterministic timeout outcomes while disabled modules remain absent" do
    options = Options.new
    options.modules.concat(%w[dns wayback])
    reports = with_outcome_export(options) do |workflow, plan|
      workflow.collect_error(plan, "dns", ArgumentError.new("invalid response")).should be_nil
      workflow.collect_error(plan, "wayback", Workflow::ModuleTimeout.new("module exceeded 24.0s")).should be_nil
      workflow.collect_error(plan, "arch", ArgumentError.new("disabled collect must not run")).should be_nil
      plan.state.modules.dns.should be_nil
      plan.state.modules.wayback.should be_nil
    end
    modules = JSON.parse(reports["json"])["modules"]
    modules["dns"].should eq(JSON.parse(%({"status":"failed","error":"ArgumentError: invalid response","timed_out":false,"module":"dns","label":"DNS Enumeration"})))
    timeout = modules["wayback"]
    timeout["status"].as_s.should eq("failed")
    timeout["timed_out"].as_bool.should be_true
    timeout["module"].as_s.should eq("wayback")
    timeout["label"].as_s.should eq("WayBack Machine")
    timeout["error"].as_s.should eq("Nokizaru::CLI::Workflow::ModuleTimeout: module exceeded 24.0s")
    modules.as_h.keys.should eq(%w[dns wayback])
    %w[txt html].each do |format|
      reports[format].should contain("dns")
      reports[format].should contain("wayback")
      reports[format].should contain("invalid response")
      reports[format].should contain("module exceeded 24.0s")
      reports[format].should contain("timed_out")
      reports[format].should_not contain("architecture_fingerprinting")
    end
    JSON.parse(reports["json"])["artifacts"].as_h.should be_empty
  end

  it "exports the archived unresolved-IP port skip envelope in every format" do
    options = Options.new
    options.modules << "ps"
    reports = with_outcome_export(options) { |workflow, plan| workflow.execute!(plan) }
    modules = JSON.parse(reports["json"])["modules"]
    modules.as_h.keys.should eq(["portscan"])
    modules["portscan"].should eq(JSON.parse(%({"status":"skipped","error":"Target IP address could not be resolved: could not resolve example.com","open_ports":[],"ports":[]})))
    %w[txt html].each do |format|
      reports[format].should contain("portscan")
      reports[format].should contain("skipped")
      reports[format].should contain("Target IP address could not be resolved")
      reports[format].should contain("open_ports")
    end
    JSON.parse(reports["json"])["artifacts"].as_h.should be_empty
  end

  it "withholds credential-bearing failure details from logs and exports" do
    options = Options.new
    options.modules << "dns"
    options.request_headers << "Authorization: Bearer operator-credential"
    reports = with_outcome_export(options) do |workflow, plan|
      ENV["NK_WAPPALYZER_KEY"] = "environment-credential"
      message = "bad <response>\noperator-\e[31mcredential\e[0m\u202E environment-\e[31mcredential\e[0m\e]52;c;clipboard\a"
      workflow.collect_error(plan, "dns", ArgumentError.new(message))
    end
    error = JSON.parse(reports["json"])["modules"]["dns"]["error"].as_s
    error.should eq("ArgumentError: Module failed; credential-bearing error detail withheld")
    reports["log"].should contain(error)
    reports["txt"].should contain(error)
    reports["html"].should contain(error)
    %w[operator-credential environment-credential clipboard].each do |secret|
      reports.each_value(&.should_not(contain(secret)))
    end
  end

  it "sanitizes ordinary failure details and escapes HTML without changing JSON text" do
    options = Options.new
    options.modules << "dns"
    reports = with_outcome_export(options) do |workflow, plan|
      workflow.collect_error(plan, "dns", ArgumentError.new("bad <response>\n\e[31mreply\e[0m\u202E\e]52;c;clipboard\a"))
    end
    error = JSON.parse(reports["json"])["modules"]["dns"]["error"].as_s
    error.should eq("ArgumentError: bad <response>reply")
    reports["log"].should contain(error)
    reports["txt"].should contain(error)
    reports["html"].should contain("bad &lt;response&gt;reply")
    reports.each_value(&.should_not(contain("clipboard")))
  end

  it "withholds oversized failure details rather than exporting a truncated credential" do
    options = Options.new
    options.modules << "dns"
    reports = with_outcome_export(options) do |workflow, plan|
      ENV["NK_WAPPALYZER_KEY"] = "boundary-credential"
      workflow.collect_error(plan, "dns", ArgumentError.new("x" * 1000 + "boundary-credential" * 10))
    end
    error = JSON.parse(reports["json"])["modules"]["dns"]["error"].as_s
    error.should eq("ArgumentError: Module failed; error detail exceeded safety limit")
    reports.each_value { |text| text.should_not contain("boundary-credential") }
  end

  it "stores one failure per module under every archived storage key" do
    options = Options.new
    options.full = true
    reports = with_outcome_export(options) do |workflow, plan|
      Options::MODULE_ORDER.each do |key|
        workflow.collect_error(plan, key, ArgumentError.new("invalid response"))
      end
      plan.state.modules.outcomes.size.should eq(10)
    end
    modules = JSON.parse(reports["json"])["modules"].as_h
    modules.keys.sort!.should eq(%w[headers sslinfo whois dns subdomains architecture_fingerprinting portscan crawler directory_enum wayback].sort)
    modules.each_value { |outcome| outcome["timed_out"].as_bool.should be_false }
  end

  it "keeps internal filesystem paths out of failure exports and logs" do
    options = Options.new
    options.modules << "dir"
    reports = with_outcome_export(options) do |workflow, plan|
      workflow.collect_error(plan, "dir", File::Error.new("cannot open", file: "/internal/private/wordlist"))
    end
    error = JSON.parse(reports["json"])["modules"]["directory_enum"]["error"].as_s
    error.should eq("File::Error: Module failed; check local file access")
    reports.each_value { |text| text.should_not contain("/internal/private/wordlist") }
  end
end
