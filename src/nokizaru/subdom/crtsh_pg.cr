require "socket"

module Nokizaru
  module Subdom
    # A minimal read-only PostgreSQL v3 client: just enough to query crt.sh's
    # public certwatch database (user "guest", no password, sslmode=disable).
    # crt.sh serves certificate-transparency data far more reliably over Postgres
    # than over its degraded HTTP JSON frontend (502s, timeouts), so this is the
    # crt.sh provider's primary path, with HTTP as the fallback. Hand-rolled with
    # no pg shard, like Nokizaru's hand-rolled HTTP/2 and DNS wire, to stay
    # dependency-free. Only the simple-query protocol over plaintext TCP is
    # implemented: no TLS, no auth beyond "trust", no prepared statements.
    #
    # Security: the sole value inlined into SQL is the target host, refused unless
    # it matches a strict hostname shape (SAFE_HOST), and quoted defensively, so
    # nothing injectable reaches the query. The connection is read-only as guest.
    module CrtShPg
      HOST     = "crt.sh"
      PORT     = 5432
      USER     = "guest"
      DATABASE = "certwatch"
      VERSION  = 0x0003_0000 # protocol 3.0

      # A valid DNS hostname: the only thing inlined into the SQL. The scan target
      # is already validated upstream; this is defense in depth.
      SAFE_HOST = /\A[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,251}[a-zA-Z0-9])?\z/

      class ProtocolError < Exception
      end

      # Queries crt.sh over Postgres and returns the NAME_VALUE rows (each may be
      # a newline-joined SAN list). Raises on any connection/protocol failure so
      # the caller can fall back to HTTP. timeout_s bounds connect and reads.
      def self.query(host : String, timeout_s : Float64) : Array(String)
        raise ProtocolError.new("unsafe host for pg query") unless host.matches?(SAFE_HOST)

        budget = timeout_s.clamp(1.0, 30.0)
        socket = TCPSocket.new(HOST, PORT, connect_timeout: {budget, 8.0}.min.seconds)
        socket.read_timeout = budget.seconds
        socket.write_timeout = {budget, 8.0}.min.seconds
        begin
          run_over(socket, host, (budget * 1000).to_i)
        ensure
          socket.close rescue nil
        end
      end

      # The protocol over any duplex IO (a socket in production, a stapled canned
      # stream in tests): startup handshake, then one simple query carrying the
      # statement timeout and the NAME_VALUE select, collected into names.
      def self.run_over(io : IO, host : String, statement_timeout_ms : Int32 = 20_000) : Array(String)
        io.write(startup_message)
        io.flush
        await_ready(io)
        io.write(query_message(sql_for(host, statement_timeout_ms)))
        io.flush
        collect_names(io)
      end

      # ---- encoders (pure) ----

      # The startup packet has no type byte: a self-inclusive length, the protocol
      # version, then null-terminated key/value pairs ending with an empty key.
      def self.startup_message : Bytes
        body = IO::Memory.new
        body.write_bytes(VERSION.to_i32, IO::ByteFormat::BigEndian)
        {"user" => USER, "database" => DATABASE}.each do |key, value|
          body << key
          body.write_byte(0_u8)
          body << value
          body.write_byte(0_u8)
        end
        body.write_byte(0_u8)
        framed = IO::Memory.new
        framed.write_bytes((body.size + 4).to_i32, IO::ByteFormat::BigEndian)
        framed.write(body.to_slice)
        framed.to_slice
      end

      # A simple Query message: 'Q', self-inclusive length, the SQL, a null.
      def self.query_message(sql : String) : Bytes
        io = IO::Memory.new
        io.write_byte('Q'.ord.to_u8)
        io.write_bytes((sql.bytesize + 5).to_i32, IO::ByteFormat::BigEndian)
        io << sql
        io.write_byte(0_u8)
        io.to_slice
      end

      def self.sql_for(host : String, statement_timeout_ms : Int32) : String
        esc = host.gsub('\'', "''")
        timeout = statement_timeout_ms.clamp(1_000, 60_000)
        "SET statement_timeout TO #{timeout}; " \
        "SELECT DISTINCT cai.NAME_VALUE FROM certificate_and_identities cai " \
        "WHERE plainto_tsquery('certwatch', '#{esc}') @@ identities(cai.CERTIFICATE) " \
        "AND cai.NAME_VALUE ILIKE ('%' || '#{esc}' || '%') LIMIT 10000;"
      end

      # ---- decoders ----

      # Reads messages until ReadyForQuery, accepting only trust auth; raises on an
      # auth demand (no password support) or an ErrorResponse.
      private def self.await_ready(io : IO) : Nil
        loop do
          type, payload = read_message(io)
          case type.chr
          when 'R'
            code = payload.size >= 4 ? decode_i32(payload, 0) : -1
            raise ProtocolError.new("authentication required (#{code})") unless code == 0
          when 'E' then raise ProtocolError.new(error_message(payload))
          when 'Z' then return
          else # ParameterStatus, BackendKeyData, NoticeResponse: ignore
          end
        end
      end

      # Reads query responses, collecting the first (NAME_VALUE) column of every
      # DataRow until ReadyForQuery; raises on ErrorResponse.
      private def self.collect_names(io : IO) : Array(String)
        names = [] of String
        loop do
          type, payload = read_message(io)
          case type.chr
          when 'D'
            if value = first_column(payload)
              value.each_line { |line| stripped = line.strip; names << stripped unless stripped.empty? }
            end
          when 'E' then raise ProtocolError.new(error_message(payload))
          when 'Z' then return names
          else # RowDescription, CommandComplete, NoticeResponse: ignore
          end
        end
      end

      # A backend message: a type byte, a self-inclusive Int32 length, then the
      # payload (length minus the four length bytes).
      private def self.read_message(io : IO) : {UInt8, Bytes}
        type = io.read_byte || raise ProtocolError.new("connection closed")
        length = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
        raise ProtocolError.new("invalid message length") if length < 4
        payload = Bytes.new(length - 4)
        io.read_fully(payload) unless payload.empty?
        {type, payload}
      end

      # The first column's text of a DataRow, or nil when absent or SQL NULL.
      private def self.first_column(payload : Bytes) : String?
        return nil if payload.size < 2
        return nil if decode_i16(payload, 0) < 1
        return nil if payload.size < 6

        length = decode_i32(payload, 2)
        return nil if length < 0
        return "" if length == 0
        return nil if payload.size < 6 + length

        String.new(payload[6, length])
      end

      # Extracts the human message (field 'M') from an ErrorResponse payload.
      private def self.error_message(payload : Bytes) : String
        reader = IO::Memory.new(payload)
        message = ""
        loop do
          field = reader.read_byte
          break if field.nil? || field == 0

          value = reader.gets('\u0000', chomp: true) || ""
          message = value if field.chr == 'M'
        end
        message.empty? ? "postgres error" : message
      end

      private def self.decode_i32(bytes : Bytes, offset : Int32) : Int32
        IO::ByteFormat::BigEndian.decode(Int32, bytes[offset, 4])
      end

      private def self.decode_i16(bytes : Bytes, offset : Int32) : Int16
        IO::ByteFormat::BigEndian.decode(Int16, bytes[offset, 2])
      end
    end
  end
end
