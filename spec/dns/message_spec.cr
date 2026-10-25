require "../spec_helper"
require "../support/dns_test_server"
require "../../src/nokizaru/dns/message"

describe Nokizaru::Dns::Message do
  describe ".build_query" do
    it "encodes a recursive IN query with length-prefixed labels" do
      query = Nokizaru::Dns::Message.build_query("example.com", 1_u16, 0x1234_u16)

      query[0].should eq(0x12) # transaction id
      query[1].should eq(0x34)
      query[2].should eq(0x01) # flags: RD=1
      query[3].should eq(0x00)
      query[4].should eq(0x00) # QDCOUNT = 1
      query[5].should eq(0x01)

      query[12].should eq(7) # label "example"
      String.new(query[13, 7]).should eq("example")
      query[20].should eq(3) # label "com"
      String.new(query[21, 3]).should eq("com")
      query[24].should eq(0) # root terminator

      query[25].should eq(0) # QTYPE = A (1)
      query[26].should eq(1)
      query[27].should eq(0) # QCLASS = IN (1)
      query[28].should eq(1)
      query.size.should eq(29)
    end

    it "rejects a label longer than 63 octets" do
      expect_raises(Nokizaru::Dns::MalformedMessage) do
        Nokizaru::Dns::Message.build_query("#{"a" * 64}.com", 1_u16, 1_u16)
      end
    end

    it "does not apply presentation escaping or case folding to query bytes" do
      query = Nokizaru::Dns::Message.build_query("MiXeD\\name.example", 16_u16, 1_u16)
      query[12].should eq(10)
      query[13, 10].should eq("MiXeD\\name".to_slice)
    end
  end

  describe ".parse" do
    it "reads the answer section, following a compressed owner name" do
      query = Nokizaru::Dns::Message.build_query("example.com", 1_u16, 0xABCD_u16)
      response = DnsTestServer.response(query, [{1_u16, Bytes[93, 184, 216, 34]}])

      message = Nokizaru::Dns::Message.parse(response)
      message.id.should eq(0xABCD_u16)
      message.truncated?.should be_false
      message.answers.size.should eq(1)
      message.answers.first.type.should eq(1_u16)
      message.answers.first.rdata.should eq(Bytes[93, 184, 216, 34])
    end

    it "surfaces the TC bit so the caller can retry over TCP" do
      query = Nokizaru::Dns::Message.build_query("example.com", 1_u16, 1_u16)
      response = DnsTestServer.response(query, [] of DnsTestServer::Answer, truncated: true)

      Nokizaru::Dns::Message.parse(response).truncated?.should be_true
    end

    it "rejects a message shorter than a header" do
      expect_raises(Nokizaru::Dns::MalformedMessage, "shorter than a header") do
        Nokizaru::Dns::Message.parse(Bytes.new(4))
      end
    end

    it "rejects a message past the size cap" do
      expect_raises(Nokizaru::Dns::MalformedMessage, "size cap") do
        Nokizaru::Dns::Message.parse(Bytes.new(Nokizaru::Dns::Message::MAX_MESSAGE + 1))
      end
    end
  end

  describe ".read_name" do
    it "matches dnsruby label escaping byte for byte, including invalid UTF-8" do
      labels = {
        Bytes[0]                                                => "\\000",
        Bytes[97, 46, 98, 92, 99]                               => "a\\.b\\\\c",
        Bytes[34, 36, 40, 41, 59, 64, 32, 9, 27, 127, 128, 255] => "\\\"\\$\\(\\)\\;\\@\\032\\009\\027\\127\\128\\255",
        Bytes[0xc3, 0xa9]                                       => "\\195\\169",
      }
      labels.each do |label, escaped|
        wire = IO::Memory.new
        wire.write_byte(label.size.to_u8)
        wire.write(label)
        wire.write(DnsTestServer.encode_name("EXample.com"))
        name, consumed = Nokizaru::Dns::Message.read_name(wire.to_slice, 0)
        name.should eq("#{escaped}.EXample.com")
        name.ascii_only?.should be_true
        consumed.should eq(wire.size)
      end
    end

    it "decompresses a name embedded in rdata via a pointer to the question" do
      # A CNAME whose rdata is "alias" followed by a pointer to "example.com".
      query = Nokizaru::Dns::Message.build_query("example.com", 5_u16, 1_u16)
      rdata = Bytes[5, 'a'.ord.to_u8, 'l'.ord.to_u8, 'i'.ord.to_u8, 'a'.ord.to_u8, 's'.ord.to_u8, 0xC0, 0x0C]
      response = DnsTestServer.response(query, [{5_u16, rdata}])

      record = Nokizaru::Dns::Message.parse(response).answers.first
      name, consumed = Nokizaru::Dns::Message.read_name(record.message, record.rdata_offset)
      name.should eq("alias.example.com")
      consumed.should eq(8) # "alias" label (6 bytes) + the 2-byte pointer
    end

    it "escapes compressed labels while counting only their sequential wire bytes" do
      wire = Bytes[1, 0, 0, 0xc0, 0]
      Nokizaru::Dns::Message.read_name(wire, 3).should eq({"\\000", 2})
    end

    it "bounds escaped output to four ASCII bytes per wire label byte" do
      [1, Nokizaru::Dns::Message::MAX_LABEL].each do |size|
        wire = Bytes.new(size + 2, 0xff_u8)
        wire[0] = size.to_u8
        wire[size + 1] = 0
        name, consumed = Nokizaru::Dns::Message.read_name(wire, 0)
        name.should eq("\\255" * size)
        name.bytesize.should eq(4 * size)
        consumed.should eq(size + 2)
      end
    end

    it "rejects a compression pointer loop instead of spinning" do
      expect_raises(Nokizaru::Dns::MalformedMessage, "loop") do
        Nokizaru::Dns::Message.read_name(Bytes[0xC0, 0x00], 0)
      end
    end

    it "rejects a label that overruns the message" do
      expect_raises(Nokizaru::Dns::MalformedMessage, "overruns") do
        Nokizaru::Dns::Message.read_name(Bytes[5, 'a'.ord.to_u8], 0)
      end
    end
  end
end
