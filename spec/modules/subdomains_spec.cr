require "../spec_helper"
require "../../src/nokizaru/modules/subdomains"
require "../../src/nokizaru/context"

# Returns a canned outcome without any network, so the enumerator's scope/dedup
# and the module's health aggregation can be tested offline.
private class CannedProvider < Nokizaru::Subdom::Provider
  def initialize(@pname : String, @found : Array(String), @state : String = "healthy")
  end

  def name : String
    @pname
  end

  def build(host : String, keys : Hash(String, String)) : Nokizaru::Subdom::Request
    Nokizaru::Subdom::Request.new("http://unused.invalid")
  end

  def parse(host : String, body : String) : Array(String)
    [] of String
  end

  def run(host : String, pool : Nokizaru::Http::Pool, keys : Hash(String, String), timeout : Float64, *, clock : Proc(Time::Instant) = -> { Time.instant }, deadline : Time::Instant? = nil) : Nokizaru::Subdom::Outcome
    count = @state == "healthy" ? @found.size : nil
    Nokizaru::Subdom::Outcome.new(@pname, @state, @found, elapsed_s: 0.5, result_count: count)
  end
end

describe Nokizaru::Modules::Subdomains do
  describe ".collect" do
    it "scopes, dedups, and summarizes provider health" do
      providers = [
        CannedProvider.new("A", ["www.example.com", "ftp.example.com", "out.of.scope.net"]),
        CannedProvider.new("B", ["www.example.com"], "skipped"),
      ] of Nokizaru::Subdom::Provider

      result = Nokizaru::Modules::Subdomains.collect("example.com", 10.0, Nokizaru::Http::Pool.new, providers)

      result.subdomains.should eq(["ftp.example.com", "www.example.com"]) # out-of-scope dropped, deduped, sorted
      result.provider_health.counts["total"].should eq(2)
      result.provider_health.counts["healthy"].should eq(1)
      result.provider_health.counts["skipped"].should eq(1)

      providers_health = result.provider_health.providers
      providers_health.map(&.name).should eq(["A", "B"])
      providers_health.first.status.should eq("healthy")
      providers_health.first.result_count.should eq(3)
    end

    it "reports per-provider progress to the rail" do
      providers = [
        CannedProvider.new("A", ["www.example.com"]),
        CannedProvider.new("B", ["ftp.example.com"]),
      ] of Nokizaru::Subdom::Provider
      reports = [] of String
      progress = Nokizaru::ProgressReporter.new(->(stage : String, detail : String) { reports << "#{stage} #{detail}"; nil })

      Nokizaru::Modules::Subdomains.collect("example.com", 10.0, Nokizaru::Http::Pool.new, providers, progress)

      reports.size.should eq(2) # one per provider
      reports.any?(&.matches?(/querying 2\/2 found \d+/)).should be_true
    end
  end

  describe "run-state wiring" do
    it "stores the result on modules.subdomains under the \"subdomains\" key" do
      meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-10-20T00:00:00Z")
      run = Nokizaru::RunState.new(meta)
      health = Nokizaru::Modules::Subdomains::Health.new(
        [Nokizaru::Modules::Subdomains::ProviderHealth.new("A", "healthy", result_count: 1)],
        {"total" => 1, "healthy" => 1}
      )
      run.modules.subdomains = Nokizaru::Modules::Subdomains::Result.new(["a.example.com"], health)

      run.modules.subdomains.should_not be_nil
      json = JSON.parse(run.to_json)["modules"]["subdomains"]
      json["subdomains"].as_a.map(&.as_s).should eq(["a.example.com"])
      json["provider_health"]["counts"]["total"].as_i.should eq(1)
    end
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

describe "Nokizaru::Modules::Subdomains.present" do
  it "renders the subdomain list and the total" do
    health = Nokizaru::Modules::Subdomains::Health.new([] of Nokizaru::Modules::Subdomains::ProviderHealth, {} of String => Int32)
    result = Nokizaru::Modules::Subdomains::Result.new(["a.example.com", "b.example.com"], health)
    text = present_capture { Nokizaru::Modules::Subdomains.present(result) }
    text.should contain("Results")
    text.should contain("a.example.com")
    text.should contain("Total unique subdomains found")
    text.should contain("2")
  end
end
