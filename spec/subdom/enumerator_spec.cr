require "../spec_helper"
require "../support/subdom_transport"
require "../../src/nokizaru/modules/subdomains"

# crt.sh tries Postgres first; a stub that returns empty makes it fall to HTTP
# so specs exercise the HTTP path without ever opening a socket to crt.sh:5432.
EMPTY_PG = ->(_host : String, _remaining : Float64) { [] of String }

describe Nokizaru::Subdom::Enumerator do
  it "pins the exact ordered default jobs and never dispatches quarantined sources" do
    expected = %w[AnubisDB CertSpotter crt.sh Digitorus HackerTarget RapidDNS UrlScan Wayback AlienVault BeVigil VirusTotal Shodan Chaos Censys SecurityTrails GitHub GitLab]
    Nokizaru::Modules::Subdomains::PROVIDERS.map(&.name).should eq(expected)
    # network-safe equivalent for the run: crt.sh with Postgres stubbed empty
    providers = Nokizaru::Modules::Subdomains::PROVIDERS.map do |provider|
      provider.name == "crt.sh" ? Nokizaru::Subdom::CrtSh.new(EMPTY_PG).as(Nokizaru::Subdom::Provider) : provider
    end
    keys = {} of String => String
    providers.each { |provider| provider.key_names.each { |(name, _env)| keys[name] = "key" } }
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) { subdom_response(429) })

    _, outcomes = Nokizaru::Subdom::Enumerator.new(providers).run("example.com", pool, keys, 30.0)

    outcomes.map(&.name).should eq(expected)
    pool.requests.size.should eq(17)
  end

  it "runs independent calls on a bounded pool and joins all workers" do
    providers = Array(Nokizaru::Subdom::Provider).new(25) { Nokizaru::Subdom::AnubisDB.new }
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      Fiber.yield
      subdom_response(200, %q(["a.example.com"]))
    })

    names, outcomes = Nokizaru::Subdom::Enumerator.new(providers).run("example.com", pool, {} of String => String, 30.0)

    pool.requests.size.should eq(25)
    pool.peak.should eq(Nokizaru::Subdom::Enumerator::WORKER_LIMIT)
    pool.active.should eq(0)
    outcomes.size.should eq(25)
    names.should eq(["a.example.com"])
    Fiber.yield
    pool.requests.size.should eq(25)
  end

  it "bounds queued providers and pagination by the aggregate scan budget" do
    clock = SubdomClock.new
    providers = Array(Nokizaru::Subdom::Provider).new(15) { Nokizaru::Subdom::Censys.new }
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      clock.advance(5.0)
      Fiber.yield
      subdom_response(200, censys_page)
    })

    names, outcomes = Nokizaru::Subdom::Enumerator.new(providers, -> { clock.now }).run("example.com", pool, censys_keys, 1.0)

    pool.budgets.should eq([5.0]) # Ruby's minimum scan budget
    pool.active.should eq(0)
    outcomes.size.should eq(15)
    outcomes.map(&.status).uniq!.should eq(["timeout"])
    outcomes.first.result_count.should eq(1)
    outcomes.last.reason.should eq("shared provider deadline exceeded before start")
    names.should eq(["a.example.com"])
    Fiber.yield
    pool.requests.size.should eq(1)
  end

  it "falls back to HTTP and retries gateway 5xx when Postgres yields nothing" do
    calls = 0
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      calls += 1
      calls < 3 ? subdom_response(503) : subdom_response(200, %q([{"name_value":"a.example.com\nb.example.com"}]))
    })

    result = Nokizaru::Subdom::CrtSh.new(EMPTY_PG).run("example.com", pool, {} of String => String, 30.0)

    result.status.should eq("healthy")
    result.names.sort.should eq(["a.example.com", "b.example.com"])
    pool.requests.size.should eq(3) # two 503s retried, third 200 succeeds
  end

  it "uses the Postgres result and never touches HTTP when it succeeds" do
    pg = ->(_host : String, _remaining : Float64) { ["a.example.com", "b.example.com"] }
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) { subdom_response(500) })

    result = Nokizaru::Subdom::CrtSh.new(pg).run("example.com", pool, {} of String => String, 30.0)

    result.status.should eq("healthy")
    result.names.sort.should eq(["a.example.com", "b.example.com"])
    pool.requests.size.should eq(0) # Postgres satisfied it; HTTP never called
  end

  it "stops crt.sh retrying after the bounded attempt cap on persistent 5xx" do
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) { subdom_response(502) })
    result = Nokizaru::Subdom::CrtSh.new(EMPTY_PG).run("example.com", pool, {} of String => String, 30.0)
    result.status.should eq("error")
    pool.requests.size.should eq(Nokizaru::Subdom::CrtSh::MAX_ATTEMPTS)
  end

  it "gives later single-request providers only the scan time remaining" do
    clock = SubdomClock.new
    providers = Array(Nokizaru::Subdom::Provider).new(6) { Nokizaru::Subdom::AnubisDB.new }
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      clock.advance(1.0)
      subdom_response
    })

    _, outcomes = Nokizaru::Subdom::Enumerator.new(providers, -> { clock.now }).run("example.com", pool, {} of String => String, 5.0)

    pool.budgets.should eq([5.0, 4.0, 3.0, 2.0, 1.0])
    outcomes.last.status.should eq("timeout")
    pool.active.should eq(0)
  end
end
