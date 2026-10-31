require "../support/whois_test_server"
require "../../src/nokizaru/whois/client"

# The fixture stands in for both IANA and the registry on loopback, which the
# default policy refuses, so these cases inject a permissive one.
private LOOPBACK_OK = ->(_host : String) { true }

describe Nokizaru::Whois::Client do
  it "follows the IANA referral and returns the authoritative record" do
    record = "Domain Name: example.test\nRegistrar: Example Registrar\n"
    WhoisTestServer.with_server(record) do |port|
      client = Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1", destination: LOOPBACK_OK)
      client.lookup("example.test", "test").should contain("Domain Name: example.test")
    end
  end

  it "trims the terms-of-use footer after >>>" do
    record = "Domain Name: example.test\n>>> Last update of WHOIS database <<<\n"
    WhoisTestServer.with_server(record) do |port|
      client = Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1", destination: LOOPBACK_OK)
      raw = client.lookup("example.test", "test")
      raw.should contain("Domain Name")
      raw.should_not contain("Last update")
    end
  end

  it "refuses a referral that points at an internal address" do
    # The referral arrives over plaintext TCP 43, so a server (or anyone on the
    # path) could name the operator's own network; the default policy declines
    # instead of sending the queried domain there.
    record = "Domain Name: example.test\n"
    WhoisTestServer.with_server(record) do |port|
      client = Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1")
      expect_raises(Nokizaru::Whois::ServerError, "no WHOIS server") do
        client.lookup("example.test", "test")
      end
    end
  end
end
