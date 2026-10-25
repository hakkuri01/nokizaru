require "./result"
require "../version"

module Nokizaru
  module Http
    # Always present as a mainstream browser. A self-identifying agent string
    # (our own tool name) gets 403'd by Cloudflare-fronted and WAF'd targets and
    # passive APIs, so every request looks like Chrome on macOS by default; the
    # crawler varies to a Firefox string on a bot-block retry (crawler/limits).
    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    # Accept-Encoding is deliberately omitted: `compress = true` manages it and
    # decompresses the body, which is what lets the cap bind the decoded size.
    DEFAULT_HEADERS = {
      "User-Agent" => USER_AGENT,
      "Accept"     => "*/*",
    }

    CONNECT_TIMEOUT   =    5.0
    READ_TIMEOUT      =   15.0
    WRITE_TIMEOUT     =    5.0
    OPERATION_TIMEOUT =   30.0
    READ_CHUNK_BYTES  = 16_384

    # Caps every response body at MAX_BYTES of decoded payload. The target may
    # answer with an endless body or a gzip bomb (a few KB inflating to GBs), so
    # buffering stops at the cap. Ports Ruby's BodyCap.
    module BodyCap
      MAX_BYTES = 8 * 1024 * 1024
    end

    # One persistent connection to a single origin, wrapping stdlib HTTP::Client.
    # Requests are serialized by a Mutex because a stdlib client holds one
    # connection and is not safe for concurrent requests; the concurrent modules
    # (dirrec, crawler, port scan) take their own connections per fiber in later
    # phases. Ports ConnectionPool's per-host client plus the operation deadline.
    class Client
      @client : ::HTTP::Client

      def initialize(@host : String, @port : Int32, @tls : Bool, @verify_ssl : Bool)
        @mutex = Mutex.new
        @client = build_client
      end

      def request(method : String, path : String, headers : ::HTTP::Headers, timeout_s : Float64, body : String? = nil, read_timeout_s : Float64? = nil) : Result
        @mutex.synchronize { perform(method, path, headers, timeout_s, body, read_timeout_s) }
      end

      def close : Nil
        @mutex.synchronize { close_client }
      end

      private def perform(method : String, path : String, headers : ::HTTP::Headers, timeout_s : Float64, body : String?, read_timeout_s : Float64?) : Result
        @client.read_timeout = (read_timeout_s || READ_TIMEOUT).seconds
        done = Channel(Nil).new(1)
        # fired is read in the rescue to tell a deadline close from a peer close.
        # Atomic is a struct, so it stays a closured local shared with the inline
        # watchdog below; passing it to a method would copy it and lose the write.
        fired = Atomic(Int32).new(0)
        watched = @client
        # Watchdog: close the socket when the total deadline passes, waking a read
        # blocked under a per-read timeout that never trips (a trickle attack).
        if timeout_s > 0
          spawn do
            select
            when done.receive
              # request finished within the deadline
            when timeout(timeout_s.seconds)
              fired.set(1)
              watched.close rescue nil
            end
          end
        end
        captured : Result? = nil
        begin
          @client.exec(method, path, headers: merged_headers(headers), body: body) do |response|
            captured = read_response(response)
          end
          result = captured || Result.failure(ErrorKind::Other, "no response")
          reset_connection if result.truncated?
          result
        rescue error
          reset_connection
          Result.failure(*Http.classify_error(error, fired.get != 0))
        ensure
          done.send(nil) rescue nil
        end
      end

      private def read_response(response : ::HTTP::Client::Response) : Result
        io = response.body_io?
        body, truncated = io ? read_capped(io) : {"", false}
        Result.ok(response.status_code, response.headers, body, truncated)
      end

      # Reads the decoded body in fixed chunks and stops at the budget. The stream
      # is already decompressed by HTTP::Client, so the cap binds the inflated
      # size (gzip-bomb safe). Complexity: one O(min(body, cap)) pass; memory stops
      # at the cap, never the body. truncated means the cap was reached, so unread
      # bytes may remain and the connection is reset rather than reused.
      private def read_capped(io : IO) : {String, Bool}
        buffer = IO::Memory.new
        chunk = Bytes.new(READ_CHUNK_BYTES)
        total = 0
        while total < BodyCap::MAX_BYTES
          read = io.read(chunk)
          break if read == 0
          take = {read, BodyCap::MAX_BYTES - total}.min
          buffer.write(chunk[0, take])
          total += take
        end
        {buffer.to_s, total >= BodyCap::MAX_BYTES}
      end

      private def merged_headers(extra : ::HTTP::Headers) : ::HTTP::Headers
        headers = ::HTTP::Headers.new
        DEFAULT_HEADERS.each { |name, value| headers[name] = value }
        extra.each { |name, values| headers[name] = values }
        headers
      end

      # Per-operation stdlib timeouts guard a single stalled connect/read/write;
      # the total operation deadline is enforced separately by the watchdog, so
      # these stay at their config values and never shrink to the deadline (which
      # would race the watchdog at the same instant).
      private def build_client : ::HTTP::Client
        client = ::HTTP::Client.new(@host, @port, tls: tls_argument)
        client.compress = true
        client.connect_timeout = CONNECT_TIMEOUT.seconds
        client.read_timeout = READ_TIMEOUT.seconds
        client.write_timeout = WRITE_TIMEOUT.seconds
        client
      end

      private def tls_argument : Bool | OpenSSL::SSL::Context::Client
        return false unless @tls
        return true if @verify_ssl

        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        context
      end

      private def reset_connection : Nil
        close_client
        @client = build_client
      end

      private def close_client : Nil
        @client.close
      rescue
        nil
      end
    end
  end
end
