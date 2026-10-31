require "socket"
require "../destination"

module Nokizaru
  module Whois
    # No WHOIS server could be found for the suffix (the IANA referral named
    # none and the special-case table has no entry).
    class ServerError < Exception
    end

    # A transport failure talking to a WHOIS server (connect, timeout, reset).
    class ConnectionError < Exception
    end

    # A hand-rolled WHOIS client over TCP port 43, replacing the Ruby
    # `whois` gem. Server selection asks whois.iana.org for the TLD's referral,
    # with a small table for suffixes that need a direct server or a query flag;
    # like the Ruby client (referral: false) it does not chase the thin->thick
    # registrar referral, it reads the authoritative server once. Responses are
    # size- and deadline-bounded against a hostile or endless server. The port
    # defaults to 43 and the IANA host is injectable only so a loopback fixture
    # can stand in for both.
    class Client
      IANA_HOST       = "whois.iana.org"
      WHOIS_PORT      =     43
      DEFAULT_TIMEOUT =   10.0
      READ_CHUNK      = 16_384
      # A WHOIS record is text; cap it so a flooding server cannot grow memory.
      MAX_RESPONSE = 256 * 1024

      # TLD => authoritative server, for suffixes where the IANA referral is
      # unreliable or the extra round trip is worth skipping.
      SPECIAL_SERVERS = {
        "com" => "whois.verisign-grs.com",
        "net" => "whois.verisign-grs.com",
        "org" => "whois.pir.org",
        "io"  => "whois.nic.io",
        "de"  => "whois.denic.de",
        "jp"  => "whois.jprs.jp",
      }

      # server => a query prefix that server needs for a full record.
      QUERY_PREFIX = {"whois.denic.de" => "-T dn,ace "}

      def initialize(@timeout_s : Float64 = DEFAULT_TIMEOUT, @port : Int32 = WHOIS_PORT, @iana_host : String = IANA_HOST, @destination : Proc(String, Bool) = Destination.public_policy)
      end

      # The raw WHOIS text for a query, with the trailing terms-of-use footer
      # (everything from ">>>") trimmed as the Ruby client did. Raises
      # ServerError when no server is known, ConnectionError on transport loss.
      def lookup(query : String, tld : String) : String
        server = resolve_server(tld)
        raise ServerError.new("no WHOIS server for suffix .#{tld}") if server.nil?

        exchange(server, query_line(server, query)).split(">>>", 2)[0]
      end

      private def resolve_server(tld : String) : String?
        SPECIAL_SERVERS[tld.downcase]? || iana_referral(tld)
      end

      # Asks whois.iana.org for the suffix and reads its "whois:" referral line.
      # The answer arrives over plaintext TCP 43, so it is server data: a referral
      # that is not a public registry host is refused rather than dialed.
      private def iana_referral(tld : String) : String?
        exchange(@iana_host, tld).each_line do |line|
          stripped = line.strip
          next unless stripped.downcase.starts_with?("whois:")

          server = stripped[6..].strip
          return @destination.call(server) ? server : nil
        end
        nil
      rescue ConnectionError
        nil
      end

      private def query_line(server : String, query : String) : String
        "#{QUERY_PREFIX[server]? || ""}#{query}"
      end

      private def exchange(server : String, query : String) : String
        socket = TCPSocket.new(server, @port, connect_timeout: @timeout_s)
        begin
          socket.read_timeout = @timeout_s.seconds
          socket.write_timeout = @timeout_s.seconds
          socket.print("#{query}\r\n")
          socket.flush
          read_capped(socket)
        ensure
          socket.close rescue nil
        end
      rescue ex : IO::Error | Socket::Error
        raise ConnectionError.new(ex.message)
      end

      # Reads until the server closes or the cap is hit, O(min(response, cap)).
      private def read_capped(socket : TCPSocket) : String
        buffer = IO::Memory.new
        chunk = Bytes.new(READ_CHUNK)
        total = 0
        while total < MAX_RESPONSE
          read = socket.read(chunk)
          break if read == 0

          take = {read, MAX_RESPONSE - total}.min
          buffer.write(chunk[0, take])
          total += take
        end
        buffer.to_s
      end
    end
  end
end
