require "./spec_helper"
require "../src/nokizaru/destination"

private alias Destination = Nokizaru::Destination

private NO_DNS = ->(_host : String) { nil.as(String?) }

describe Nokizaru::Destination do
  it "classifies the address families a scan must not reach" do
    %w[127.0.0.1 ::1 10.0.0.5 192.168.1.1 172.16.0.1 169.254.169.254 fe80::1 fd00::1 0.0.0.0].each do |value|
      Destination.internal_address?(value).should be_true
    end
    %w[8.8.8.8 93.184.216.34 2606:2800:220:1:248:1893:25c8:1946].each do |value|
      Destination.internal_address?(value).should be_false
    end
  end

  it "treats a non-address string as no address at all" do
    Destination.internal_address?("example.com").should be_false
    Destination.internal_address?("").should be_false
  end

  describe ".public_host?" do
    it "accepts a name that resolves to a public address" do
      Destination.public_host?("example.com", ->(_h : String) { "93.184.216.34".as(String?) }).should be_true
    end

    it "refuses a name that resolves to an internal address" do
      # The rebinding case: an in-scope name whose owner points it at the
      # operator's own network.
      Destination.public_host?("pivot.example.com", ->(_h : String) { "127.0.0.1".as(String?) }).should be_false
      Destination.public_host?("metadata.example.com", ->(_h : String) { "169.254.169.254".as(String?) }).should be_false
    end

    it "refuses a name that does not resolve, and never asks about a malformed one" do
      asked = 0
      resolve = ->(_h : String) { asked += 1; nil.as(String?) }
      Destination.public_host?("example.com", resolve).should be_false
      Destination.public_host?("bad host.example.com", resolve).should be_false
      Destination.public_host?("", resolve).should be_false
      asked.should eq(1)
    end

    it "decides an address literal without resolving" do
      asked = 0
      resolve = ->(_h : String) { asked += 1; nil.as(String?) }
      Destination.public_host?("93.184.216.34", resolve).should be_true
      Destination.public_host?("127.0.0.1", resolve).should be_false
      asked.should eq(0)
    end
  end

  describe ".policy" do
    it "refuses internal destinations for a public target" do
      policy = Destination.policy(allow_internal: false, resolve: ->(_h : String) { "10.0.0.5".as(String?) })
      policy.call("intranet.example.com").should be_false
    end

    it "allows them when the operator's own target is internal" do
      policy = Destination.policy(allow_internal: true, resolve: NO_DNS)
      policy.call("127.0.0.1").should be_true
      policy.call("anything.example.com").should be_true
    end
  end
end
