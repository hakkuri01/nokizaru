require "../spec_helper"
require "../support/dns_test_server"
require "../../src/nokizaru/dns/presentation"

private def record(type : UInt16, rdata : Bytes) : Nokizaru::Dns::Record
  # A self-contained record: the message is the rdata itself at offset 0, so
  # any name inside must use full labels (no back-pointers), which is how these
  # fixtures build them.
  Nokizaru::Dns::Record.new(type, rdata, rdata, 0)
end

private def concat(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |part| io.write(part) }
  io.to_slice
end

private def present(type : UInt16, rdata : Bytes) : String
  Nokizaru::Dns::Presentation.format(record(type, rdata))
end

describe Nokizaru::Dns::Presentation do
  it "formats an A record as dotted quad" do
    present(1_u16, Bytes[93, 184, 216, 34]).should eq("93.184.216.34")
  end

  it "formats an AAAA record in RFC 5952 compressed form" do
    rdata = Bytes[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    present(28_u16, rdata).should eq("2001:db8::1")
  end

  it "formats a name-only record (NS)" do
    present(2_u16, DnsTestServer.encode_name("ns1.example.com")).should eq("ns1.example.com")
  end

  it "formats an MX record as preference and exchange" do
    rdata = concat(Bytes[0, 10], DnsTestServer.encode_name("mail.example.com"))
    present(15_u16, rdata).should eq("10 mail.example.com")
  end

  it "formats a single-string TXT record verbatim" do
    present(16_u16, DnsTestServer.char_string("v=spf1 -all")).should eq("v=spf1 -all")
  end

  it "base64-encodes a TXT string that holds binary bytes" do
    present(16_u16, DnsTestServer.char_string("\x00\x01\x02")).should eq(Base64.strict_encode("\x00\x01\x02"))
  end

  it "formats a SOA record" do
    rdata = concat(
      DnsTestServer.encode_name("ns.example.com"),
      DnsTestServer.encode_name("host.example.com"),
      Bytes[0, 0, 0, 1], Bytes[0, 0, 0, 2], Bytes[0, 0, 0, 3], Bytes[0, 0, 0, 4], Bytes[0, 0, 0, 5]
    )
    present(6_u16, rdata).should eq("ns.example.com host.example.com 1 2 3 4 5")
  end

  it "formats an SRV record" do
    rdata = concat(Bytes[0, 10], Bytes[0, 60], Bytes[0x13, 0xc4], DnsTestServer.encode_name("sip.example.com"))
    present(33_u16, rdata).should eq("10 60 5060 sip.example.com")
  end

  it "formats a CAA record" do
    rdata = concat(Bytes[0], DnsTestServer.char_string("issue"), "letsencrypt.org".to_slice)
    present(257_u16, rdata).should eq("0 issue letsencrypt.org")
  end

  it "formats a DS record with an uppercase hex digest" do
    rdata = concat(Bytes[0x30, 0x39], Bytes[13], Bytes[2], "abcdef".hexbytes)
    present(43_u16, rdata).should eq("12345 13 2 ABCDEF")
  end

  it "formats an SSHFP record with an uppercase hex fingerprint" do
    rdata = concat(Bytes[1], Bytes[2], "deadbeef".hexbytes)
    present(44_u16, rdata).should eq("1 2 DEADBEEF")
  end

  it "falls back to the RFC 3597 generic form for an opaque type (LOC)" do
    present(29_u16, Bytes[1, 2, 3]).should eq("\\# 3 010203")
  end

  it "falls back to the generic form for an unknown type" do
    present(9999_u16, Bytes[0xAB]).should eq("\\# 1 AB")
  end

  it "falls back to the generic form when an exact rdata is malformed" do
    # An A record needs four octets; a short rdata must not raise.
    present(1_u16, Bytes[1, 2]).should eq("\\# 2 0102")
  end
end
