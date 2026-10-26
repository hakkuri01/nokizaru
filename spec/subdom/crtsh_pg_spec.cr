require "../spec_helper"
require "../../src/nokizaru/subdom/crtsh_pg"

private def i32(value : Int) : Bytes
  io = IO::Memory.new
  io.write_bytes(value.to_i32, IO::ByteFormat::BigEndian)
  io.to_slice
end

private def i16(value : Int) : Bytes
  io = IO::Memory.new
  io.write_bytes(value.to_i16, IO::ByteFormat::BigEndian)
  io.to_slice
end

# A backend message: type byte, self-inclusive Int32 length, payload.
private def pg_msg(type : Char, payload : Bytes) : Bytes
  io = IO::Memory.new
  io.write_byte(type.ord.to_u8)
  io.write_bytes((payload.size + 4).to_i32, IO::ByteFormat::BigEndian)
  io.write(payload)
  io.to_slice
end

private def data_row(value : String) : Bytes
  io = IO::Memory.new
  io.write(i16(1))
  io.write(i32(value.bytesize))
  io << value
  pg_msg('D', io.to_slice)
end

private def cat(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

private def run_canned(server_bytes : Bytes) : Array(String)
  reader = IO::Memory.new(server_bytes)
  writer = IO::Memory.new
  stapled = IO::Stapled.new(reader, writer)
  Nokizaru::Subdom::CrtShPg.run_over(stapled, "example.com")
end

describe Nokizaru::Subdom::CrtShPg do
  it "encodes a startup message with the protocol version and user/database" do
    bytes = Nokizaru::Subdom::CrtShPg.startup_message
    IO::ByteFormat::BigEndian.decode(Int32, bytes[0, 4]).should eq(bytes.size)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[4, 4]).should eq(0x0003_0000)
    String.new(bytes[8, bytes.size - 8]).should eq("user\u0000guest\u0000database\u0000certwatch\u0000\u0000")
  end

  it "encodes a simple query message" do
    bytes = Nokizaru::Subdom::CrtShPg.query_message("SELECT 1")
    bytes[0].should eq('Q'.ord.to_u8)
    IO::ByteFormat::BigEndian.decode(Int32, bytes[1, 4]).should eq(8 + 5)
    String.new(bytes[5, 8]).should eq("SELECT 1")
    bytes[bytes.size - 1].should eq(0_u8)
  end

  it "reads NAME_VALUE rows from a full handshake and query exchange" do
    stream = cat(
      pg_msg('R', i32(0)),               # AuthenticationOk
      pg_msg('Z', Bytes['I'.ord.to_u8]), # ReadyForQuery
      pg_msg('C', "SET\u0000".to_slice), # the SET statement completing
      data_row("a.example.com\nb.example.com"),
      data_row("c.example.com"),
      pg_msg('C', "SELECT 2\u0000".to_slice),
      pg_msg('Z', Bytes['I'.ord.to_u8]),
    )
    run_canned(stream).should eq(["a.example.com", "b.example.com", "c.example.com"])
  end

  it "raises on an ErrorResponse so the caller can fall back to HTTP" do
    err = cat("SERROR\u0000".to_slice, "Mrelation missing\u0000".to_slice, Bytes[0_u8])
    stream = cat(pg_msg('R', i32(0)), pg_msg('Z', Bytes['I'.ord.to_u8]), pg_msg('E', err))
    expect_raises(Nokizaru::Subdom::CrtShPg::ProtocolError, "relation missing") do
      run_canned(stream)
    end
  end

  it "rejects an unsafe host before any connection" do
    expect_raises(Nokizaru::Subdom::CrtShPg::ProtocolError, "unsafe host") do
      Nokizaru::Subdom::CrtShPg.query("evil' OR '1'='1", 5.0)
    end
  end
end
