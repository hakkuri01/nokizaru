require "socket"

# Loopback-only DNS fixtures for the wire-client specs. The UDP and TCP
# listeners bind 127.0.0.1 on a shared ephemeral port number (UDP and TCP port
# spaces are independent, so one number serves both), never a routable
# interface, so nothing is reachable off the machine. The responder echoes the
# query id and answers from a caller-supplied template, with the owner name of
# each answer written as a compression pointer back to the question, so the
# specs exercise name decompression too.
module DnsTestServer
  extend self

  alias Answer = {UInt16, Bytes}

  # Builds a minimal response for `query`: echoes the id, sets the response and
  # recursion flags (optionally the TC bit), copies the question verbatim, and
  # appends each answer with its owner name as a pointer to the question at
  # offset 12 (0xC00C).
  def response(query : Bytes, answers : Array(Answer), truncated : Bool = false, rcode : Int32 = 0) : Bytes
    io = IO::Memory.new
    io.write(query[0, 2]) # echo the transaction id
    flags = 0x8180_u16    # QR=1, RD=1, RA=1
    flags |= 0x0200_u16 if truncated
    flags |= (rcode & 0x0F).to_u16
    write_u16(io, flags)
    write_u16(io, 1_u16) # QDCOUNT
    write_u16(io, answers.size.to_u16)
    write_u16(io, 0_u16)                 # NSCOUNT
    write_u16(io, 0_u16)                 # ARCOUNT
    io.write(query[12, query.size - 12]) # copy the question (name + qtype + qclass)
    answers.each do |(type, rdata)|
      write_u16(io, 0xC00C_u16) # owner name: pointer to the question at offset 12
      write_u16(io, type)
      write_u16(io, 1_u16)   # class IN
      write_u32(io, 300_u32) # ttl
      write_u16(io, rdata.size.to_u16)
      io.write(rdata)
    end
    io.to_slice
  end

  # Serves one UDP query on 127.0.0.1 and replies with `answers`. When
  # `truncated` is set the reply carries the TC bit, which drives the client to
  # retry over TCP.
  def with_udp(answers : Array(Answer), truncated : Bool = false, &block : Int32 ->) : Nil
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    port = socket.local_address.port
    spawn do
      buffer = Bytes.new(4096)
      count, client = socket.receive(buffer)
      socket.send(response(buffer[0, count], answers, truncated), to: client)
    rescue
      # the fixture was torn down before a query arrived
    end
    begin
      block.call(port)
    ensure
      socket.close rescue nil
    end
  end

  # Serves a truncated UDP reply (TC set, no answers) and the full `answers`
  # over TCP on the same port, so a spec can prove the TCP fallback ran: the
  # answers can only come from the TCP path.
  def with_udp_and_tcp(answers : Array(Answer), &block : Int32 ->) : Nil
    udp = UDPSocket.new
    udp.bind("127.0.0.1", 0)
    port = udp.local_address.port
    tcp = TCPServer.new("127.0.0.1", port)
    spawn { serve_truncated_udp(udp) }
    spawn { serve_tcp(tcp, answers) }
    begin
      block.call(port)
    ensure
      udp.close rescue nil
      tcp.close rescue nil
    end
  end

  private def serve_truncated_udp(udp : UDPSocket) : Nil
    buffer = Bytes.new(4096)
    count, client = udp.receive(buffer)
    udp.send(response(buffer[0, count], [] of Answer, truncated: true), to: client)
  rescue
    # torn down
  end

  private def serve_tcp(tcp : TCPServer, answers : Array(Answer)) : Nil
    conn = tcp.accept
    begin
      length_bytes = Bytes.new(2)
      conn.read_fully(length_bytes)
      length = (length_bytes[0].to_i << 8) | length_bytes[1].to_i
      query = Bytes.new(length)
      conn.read_fully(query)
      payload = response(query, answers)
      conn.write(Bytes[(payload.size >> 8).to_u8!, (payload.size & 0xFF).to_u8!])
      conn.write(payload)
      conn.flush
    ensure
      conn.close rescue nil
    end
  rescue
    # torn down
  end

  # Serves queries on 127.0.0.1 in a loop until torn down, replying to each
  # with the answers registered for its QTYPE (an empty answer otherwise). When
  # `nxdomain` is set every reply carries rcode 3 and no answers, which drives
  # the dns module's existence probe to report the name as absent.
  def with_resolver(by_type : Hash(UInt16, Array(Answer)), nxdomain : Bool = false, &block : Int32 ->) : Nil
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    port = socket.local_address.port
    spawn { serve_resolver(socket, by_type, nxdomain) }
    begin
      block.call(port)
    ensure
      socket.close rescue nil
    end
  end

  # Encodes a domain name as length-prefixed labels for building answer rdata.
  def encode_name(name : String) : Bytes
    io = IO::Memory.new
    name.split('.') do |label|
      next if label.empty?

      io.write_byte(label.bytesize.to_u8)
      io.write(label.to_slice)
    end
    io.write_byte(0_u8)
    io.to_slice
  end

  # Encodes a <character-string> (one length byte then the octets).
  def char_string(value : String) : Bytes
    io = IO::Memory.new
    io.write_byte(value.bytesize.to_u8)
    io.write(value.to_slice)
    io.to_slice
  end

  private def serve_resolver(socket : UDPSocket, by_type : Hash(UInt16, Array(Answer)), nxdomain : Bool) : Nil
    buffer = Bytes.new(4096)
    loop do
      count, client = socket.receive(buffer)
      query = buffer[0, count].dup
      answers = nxdomain ? [] of Answer : (by_type[query_qtype(query)]? || [] of Answer)
      socket.send(response(query, answers, rcode: nxdomain ? 3 : 0), to: client)
    end
  rescue
    # the socket was closed at teardown
  end

  # Reads the QTYPE from a query by walking its (uncompressed) question name.
  private def query_qtype(query : Bytes) : UInt16
    pos = 12
    while pos < query.size && (len = query[pos].to_i) != 0
      pos += len + 1
    end
    pos += 1 # past the root label
    (query[pos].to_u16 << 8) | query[pos + 1].to_u16
  end

  private def write_u16(io : IO, value : UInt16) : Nil
    io.write_byte((value >> 8).to_u8!)
    io.write_byte((value & 0xFF).to_u8!)
  end

  private def write_u32(io : IO, value : UInt32) : Nil
    io.write_byte((value >> 24).to_u8!)
    io.write_byte((value >> 16).to_u8!)
    io.write_byte((value >> 8).to_u8!)
    io.write_byte((value & 0xFF).to_u8!)
  end
end
