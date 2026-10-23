require "../spec_helper"
require "../support/whois_test_server"
require "../../src/nokizaru/whois/client"

describe Nokizaru::Whois::Client do
  it "follows the IANA referral and returns the authoritative record" do
    record = "Domain Name: example.test\nRegistrar: Example Registrar\n"
    WhoisTestServer.with_server(record) do |port|
      client = Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1")
      client.lookup("example.test", "test").should contain("Domain Name: example.test")
    end
  end

  it "trims the terms-of-use footer after >>>" do
    record = "Domain Name: example.test\n>>> Last update of WHOIS database <<<\n"
    WhoisTestServer.with_server(record) do |port|
      client = Nokizaru::Whois::Client.new(timeout_s: 2.0, port: port, iana_host: "127.0.0.1")
      raw = client.lookup("example.test", "test")
      raw.should contain("Domain Name")
      raw.should_not contain("Last update")
    end
  end
end
