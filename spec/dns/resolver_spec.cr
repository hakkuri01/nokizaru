require "../spec_helper"
require "../../src/nokizaru/dns/resolver"

describe Nokizaru::Dns::Resolver do
  it "returns an IP literal unchanged without a lookup" do
    Nokizaru::Dns::Resolver.new.resolve("127.0.0.1").should eq("127.0.0.1")
  end

  it "resolves a loopback hostname to an address" do
    ip = Nokizaru::Dns::Resolver.new.resolve("localhost")
    ip.should_not be_nil
    ["127.0.0.1", "::1"].should contain(ip)
  end

  it "resolves with no deadline when the timeout is zero or less" do
    Nokizaru::Dns::Resolver.new.resolve("127.0.0.1", 0.0).should eq("127.0.0.1")
  end

  describe "#ip_literal?" do
    it "recognizes IPv4 and IPv6 literals" do
      resolver = Nokizaru::Dns::Resolver.new
      resolver.ip_literal?("127.0.0.1").should be_true
      resolver.ip_literal?("::1").should be_true
    end

    it "rejects a hostname" do
      Nokizaru::Dns::Resolver.new.ip_literal?("example.com").should be_false
    end
  end
end
