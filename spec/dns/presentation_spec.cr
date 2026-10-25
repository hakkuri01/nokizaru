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

  it "formats an AAAA record with dnsruby's uppercase compressed hex" do
    rdata = Bytes[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    present(28_u16, rdata).should eq("2001:DB8::1")
    rdata[14] = 0x17
    rdata[15] = 0x9a
    present(28_u16, rdata).should eq("2001:DB8::179A")
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
    rdata = concat(Bytes[0], DnsTestServer.char_string("issue"), "amazon.com".to_slice)
    present(257_u16, rdata).should eq(%(0 issue "amazon.com"))
  end

  it "formats binary DS, CDS and DLV digests as Base64 like Ruby format_rdata" do
    rdata = concat(Bytes[0x30, 0x39], Bytes[13], Bytes[2], "abcdef".hexbytes)
    [43_u16, 59_u16, 32769_u16].each do |type|
      present(type, rdata).should eq("12345 13 2 q83v")
      printable = concat(Bytes[0x30, 0x39, 13, 2], "AbCd".to_slice)
      present(type, printable).should eq("12345 13 2 AbCd")
    end
  end

  it "escapes NSEC next names without losing NUL bytes to terminal sanitizing" do
    name = concat(Bytes[1, 0], DnsTestServer.encode_name("example.com"))
    present(47_u16, concat(name, Bytes[0, 1, 0x40])).should eq("\\000.example.com A")
  end

  it "shares escaped names across name-only and structured records" do
    name = concat(Bytes[5, 97, 46, 98, 92, 99], DnsTestServer.encode_name("EXample.com"))
    escaped = "a\\.b\\\\c.EXample.com"
    [2_u16, 5_u16, 12_u16, 39_u16].each do |type|
      present(type, name).should eq(escaped)
    end
    present(15_u16, concat(Bytes[0, 10], name)).should eq("10 #{escaped}")
    present(6_u16, concat(name, name, Bytes.new(20))).should eq("#{escaped} #{escaped} 0 0 0 0 0")
  end

  it "preserves case-sensitive TXT and DNSKEY bytes outside name presentation" do
    present(16_u16, DnsTestServer.char_string("AbC\\.DeF")).should eq("AbC\\.DeF")
    present(48_u16, Bytes[1, 1, 3, 13, 0, 0x80, 0xff, 0x41]).should eq("257 3 13 AID/QQ==")
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
