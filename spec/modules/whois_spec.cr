require "../spec_helper"
require "../support/whois_test_server"
require "../support/http_test_server"
require "../../src/nokizaru/modules/whois"
require "../../src/nokizaru/run_state"

private RDAP_DOMAIN_JSON = %q({"objectClassName":"domain","ldhName":"example.test","handle":"H-123","status":["active","clientTransferProhibited"],"events":[{"eventAction":"registration","eventDate":"2020-01-01T00:00:00Z"}],"nameservers":[{"ldhName":"ns1.example.test"},{"ldhName":"ns2.example.test"},{"ldhName":"ns1.example.test"}]})

private def rdap_handler(status : Int32, body : String) : ::HTTP::Server::Context ->
  ->(ctx : ::HTTP::Server::Context) do
    ctx.response.status_code = status
    ctx.response.print(body)
    nil
  end
end

private def whois_client(port : Int32) : Nokizaru::Whois::Client
  # The fixture serves both IANA and the registry on loopback, which the default
  # destination policy refuses, so this one is permissive.
  Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1",
    destination: ->(_host : String) { true })
end

describe Nokizaru::Modules::WhoisLookup do
  describe ".classify" do
    it "reads a matching Domain Name field as registered" do
      Nokizaru::Modules::WhoisLookup.classify("Domain Name: example.test\n", "example.test").should eq(:usable)
    end

    it "reads a negative reply as not found" do
      Nokizaru::Modules::WhoisLookup.classify("No match for example.test\n", "example.test").should eq(:not_found)
    end

    it "reads an RDAP referral as retired" do
      Nokizaru::Modules::WhoisLookup.classify("This WHOIS server is retired; use RDAP instead.\n", "x").should eq(:retired)
    end

    it "reads an unsupported marker" do
      Nokizaru::Modules::WhoisLookup.classify("No whois server is available for this TLD\n", "x").should eq(:unsupported)
    end

    it "reads empty text as no data and anything else as unusable" do
      Nokizaru::Modules::WhoisLookup.classify("", "x").should eq(:no_data)
      Nokizaru::Modules::WhoisLookup.classify("unrelated banner text\n", "example.test").should eq(:unusable)
    end
  end

  describe ".collect" do
    it "reports a registered domain straight from WHOIS" do
      WhoisTestServer.with_server("Domain Name: example.test\nRegistrar: Example\n") do |port|
        result = Nokizaru::Modules::WhoisLookup.collect("example", "test", whois_client(port))

        result.status.should eq("registered")
        result.source.should eq("whois")
        result.whois.not_nil!.should contain("Domain Name: example.test")
      end
    end

    it "reports a not-found domain straight from WHOIS" do
      WhoisTestServer.with_server("No match for EXAMPLE.TEST\n") do |port|
        result = Nokizaru::Modules::WhoisLookup.collect("example", "test", whois_client(port))

        result.status.should eq("not_found")
        result.source.should eq("whois")
      end
    end

    it "falls back to RDAP when WHOIS is retired and summarizes the domain object" do
      WhoisTestServer.with_server("This WHOIS server is retired; use RDAP.\n") do |wport|
        HttpTestServer.with_server(rdap_handler(200, RDAP_DOMAIN_JSON)) do |base|
          rdap = Nokizaru::Modules::RdapClient.new(origin: base, pool: Nokizaru::Http::Pool.new)
          result = Nokizaru::Modules::WhoisLookup.collect("example", "test", whois_client(wport), rdap)

          result.status.should eq("registered")
          result.source.should eq("rdap")
          result.reasons.should eq(["whois_retired"])
          result.domain.should eq("example.test")
          result.handle.should eq("H-123")
          result.registration_status.should eq(["active", "clientTransferProhibited"])
          result.nameservers.should eq(["ns1.example.test", "ns2.example.test"]) # deduped
          event = result.events.not_nil!.first
          event.action.should eq("registration")
          event.date.should eq("2020-01-01T00:00:00Z")
          result.error.should be_nil
        end
      end
    end

    it "degrades when WHOIS is retired and RDAP errors" do
      WhoisTestServer.with_server("This WHOIS server is retired; use RDAP.\n") do |wport|
        HttpTestServer.with_server(rdap_handler(500, "upstream error")) do |base|
          rdap = Nokizaru::Modules::RdapClient.new(origin: base, pool: Nokizaru::Http::Pool.new)
          result = Nokizaru::Modules::WhoisLookup.collect("example", "test", whois_client(wport), rdap)

          result.status.should eq("degraded")
          result.source.should eq("rdap")
          result.error.should eq("No usable registration data returned")
          result.error_detail.should eq("No usable registration data returned")
          result.reasons.should eq(["whois_retired", "rdap_server_error"])
        end
      end
    end
  end

  describe "run-state wiring" do
    it "stores the result on modules.whois with the Ruby key shape" do
      meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-10-20T00:00:00Z")
      run = Nokizaru::RunState.new(meta)
      result = Nokizaru::Modules::WhoisLookup::Result.new
      result.status = "degraded"
      result.error = "boom"
      result.error_detail = "boom"
      run.modules.whois = result

      run.modules.whois.should_not be_nil
      json = JSON.parse(run.to_json)["modules"]["whois"]
      json["status"].as_s.should eq("degraded")
      json["Error"].as_s.should eq("boom")
      json["error"].as_s.should eq("boom")
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

describe "Nokizaru::Modules::WhoisLookup.present" do
  it "renders raw whois text as rows and normalized misc lines" do
    result = Nokizaru::Modules::WhoisLookup::Result.new
    result.whois = "Domain Name: example.com\nRegistrar: Example Inc\nNo match for \"FOO.COM\".\n"
    text = present_capture { Nokizaru::Modules::WhoisLookup.present(result) }
    text.should contain("Domain Name")
    text.should contain("example.com")
    text.should contain("Registrar")
    text.should contain("No match for foo.com")
  end

  it "renders an rdap summary" do
    result = Nokizaru::Modules::WhoisLookup::Result.new
    result.domain = "example.com"
    result.handle = "EX123"
    result.registration_status = ["active"]
    result.events = [Nokizaru::Modules::WhoisLookup::Event.new("registration", "2020-01-01")]
    result.nameservers = ["ns1.example.com"]
    text = present_capture { Nokizaru::Modules::WhoisLookup.present(result) }
    text.should contain("example.com")
    text.should contain("registration: 2020-01-01")
    text.should contain("ns1.example.com")
  end

  it "renders an error line when nothing else is present" do
    result = Nokizaru::Modules::WhoisLookup::Result.new
    result.error = "This domain suffix is not supported."
    present_capture { Nokizaru::Modules::WhoisLookup.present(result) }.should contain("Error : This domain suffix is not supported.")
  end
end
