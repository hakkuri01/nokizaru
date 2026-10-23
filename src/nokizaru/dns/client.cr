require "socket"
require "random"
require "./message"

module Nokizaru
  module Dns
    # Sends a DNS query to a resolver over UDP and, when the answer is truncated
    # (the TC bit), retries the same query over TCP (RFC 1035 §4.2.1). Every
    # receive is size-bounded (the parser's cap) and deadline-bounded (socket
    # timeouts), so a slow, silent, or flooding resolver cannot hang the scan or
    # grow memory without limit. Ports the dnsruby transport the Ruby tool drove
    # per record type. The port defaults to 53 and is injectable only so the
    # loopback fixture can bind a non-privileged one.
    class Client
      DEFAULT_TIMEOUT = 2.0
      DNS_PORT        =  53
      # One UDP datagram we accept. A larger answer sets TC and we move to TCP,
      # so this also caps a single UDP read; TCP reads use the parser's cap.
      UDP_BUFFER = 4096

      def initialize(@timeout_s : Float64 = DEFAULT_TIMEOUT, @port : Int32 = DNS_PORT)
      end

      # Queries `nameserver` for (name, qtype). Returns the parsed answer, or nil
      # on timeout, transport error, a response whose id does not match the
      # query, or a malformed response. The Ruby path swallowed per-record
      # resolver errors and moved on; nil is that "no answer, keep going".
      def query(name : String, qtype : UInt16, nameserver : String) : Message?
        id = rand(UInt16::MIN..UInt16::MAX)
        request = Message.build_query(name, qtype, id)

        udp = query_udp(request, nameserver)
        return nil if udp.nil?

        message = parse(udp, id)
        return nil if message.nil?
        return message unless message.truncated?

        tcp = query_tcp(request, nameserver)
        return message if tcp.nil?

        parse(tcp, id) || message
      end

      private def parse(payload : Bytes, id : UInt16) : Message?
        message = Message.parse(payload)
        message.id == id ? message : nil
      rescue MalformedMessage
        nil
      end

      private def query_udp(request : Bytes, nameserver : String) : Bytes?
        socket = UDPSocket.new(family_of(nameserver))
        begin
          socket.read_timeout = @timeout_s.seconds
          socket.connect(nameserver, @port)
          socket.send(request)
          buffer = Bytes.new(UDP_BUFFER)
          count, _ = socket.receive(buffer)
          buffer[0, count]
        ensure
          socket.close rescue nil
        end
      rescue IO::Error | Socket::Error
        nil
      end

      private def query_tcp(request : Bytes, nameserver : String) : Bytes?
        socket = TCPSocket.new(nameserver, @port, connect_timeout: @timeout_s)
        begin
          socket.read_timeout = @timeout_s.seconds
          socket.write_timeout = @timeout_s.seconds
          socket.write(length_prefixed(request))
          socket.flush
          read_tcp_message(socket)
        ensure
          socket.close rescue nil
        end
      rescue IO::Error | Socket::Error
        nil
      end

      # A TCP DNS message is framed by a 2-byte big-endian length prefix.
      private def length_prefixed(payload : Bytes) : Bytes
        framed = Bytes.new(payload.size + 2)
        framed[0] = (payload.size >> 8).to_u8!
        framed[1] = (payload.size & 0xFF).to_u8!
        payload.copy_to(framed + 2)
        framed
      end

      private def read_tcp_message(socket : TCPSocket) : Bytes?
        length_bytes = Bytes.new(2)
        socket.read_fully(length_bytes)
        length = (length_bytes[0].to_i << 8) | length_bytes[1].to_i
        return nil if length == 0
        raise MalformedMessage.new("tcp message exceeds the size cap") if length > Message::MAX_MESSAGE

        payload = Bytes.new(length)
        socket.read_fully(payload)
        payload
      rescue IO::EOFError
        nil
      end

      private def family_of(address : String) : Socket::Family
        Socket::IPAddress.new(address, 0).family
      rescue Socket::Error
        Socket::Family::INET
      end
    end
  end
end
