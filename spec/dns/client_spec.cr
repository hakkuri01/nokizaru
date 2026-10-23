require "../spec_helper"
require "../support/dns_test_server"
require "../../src/nokizaru/dns/client"

describe Nokizaru::Dns::Client do
  it "resolves a query over UDP and returns the matching answer" do
    DnsTestServer.with_udp([{1_u16, Bytes[93, 184, 216, 34]}]) do |port|
      client = Nokizaru::Dns::Client.new(timeout_s: 1.0, port: port)
      message = client.query("example.com", 1_u16, "127.0.0.1")

      message.should_not be_nil
      answers = message.not_nil!.answers
      answers.size.should eq(1)
      answers.first.type.should eq(1_u16)
      answers.first.rdata.should eq(Bytes[93, 184, 216, 34])
    end
  end

  it "retries over TCP when the UDP answer is truncated" do
    # The UDP reply carries the TC bit and no answers; the answer can only come
    # from the TCP fallback, so its presence proves the fallback ran.
    DnsTestServer.with_udp_and_tcp([{5_u16, Bytes[3, 'w'.ord.to_u8, 'w'.ord.to_u8, 'w'.ord.to_u8, 0xC0, 0x0C]}]) do |port|
      client = Nokizaru::Dns::Client.new(timeout_s: 2.0, port: port)
      message = client.query("example.com", 5_u16, "127.0.0.1")

      message.should_not be_nil
      message.not_nil!.truncated?.should be_false
      message.not_nil!.answers.size.should eq(1)
    end
  end

  it "returns nil when no resolver answers before the deadline" do
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    port = socket.local_address.port
    socket.close

    client = Nokizaru::Dns::Client.new(timeout_s: 0.3, port: port)
    client.query("example.com", 1_u16, "127.0.0.1").should be_nil
  end
end
