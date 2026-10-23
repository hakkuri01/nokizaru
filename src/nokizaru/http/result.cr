require "http/client"
require "socket"
require "openssl"

module Nokizaru
  module Http
    # How a request failed, so a module can branch on the cause without parsing a
    # message. `None` is success. Ports the Ruby HttpResult error catalog.
    enum ErrorKind
      None
      Timeout
      ConnectionRefused
      Dns
      Tls
      Closed
      Io
      Other
    end

    TIMEOUT_MESSAGE = "Connection timeout - target took too long to respond"

    # SSL handshake failures, matched by substring against the OpenSSL message
    # (downcased). Ports Nokizaru::HTTPErrorCatalog::SSL_MESSAGES.
    SSL_MESSAGES = {
      "wrong version number"      => "SSL/TLS handshake failed - server may not support HTTPS on this port",
      "certificate verify failed" => "SSL certificate verification failed - likely self-signed certificate",
      "tlsv1 alert"               => "SSL/TLS version mismatch - server requires different TLS version",
      "record layer failure"      => "SSL/TLS handshake failed - server does not support HTTPS on this port",
    }

    # A normalized HTTP outcome: either a response (status, headers, capped body)
    # or a classified error. Ports Ruby's HttpResult behind one typed interface.
    struct Result
      getter status : Int32?
      getter headers : ::HTTP::Headers
      getter body : String?
      getter? truncated : Bool
      getter error_kind : ErrorKind
      getter error_message : String?

      def initialize(
        @status : Int32?,
        @headers : ::HTTP::Headers,
        @body : String?,
        @truncated : Bool,
        @error_kind : ErrorKind,
        @error_message : String?,
      )
      end

      def self.ok(status : Int32, headers : ::HTTP::Headers, body : String, truncated : Bool) : Result
        new(status, headers, body, truncated, ErrorKind::None, nil)
      end

      def self.failure(kind : ErrorKind, message : String) : Result
        new(nil, ::HTTP::Headers.new, nil, false, kind, message)
      end

      def success? : Bool
        error_kind.none?
      end

      def error? : Bool
        !success?
      end
    end

    # Maps a transport exception to a kind and an operator-facing message. A fired
    # deadline wins over the raw exception: closing the socket to wake a blocked
    # read surfaces as an IO error, but the cause the operator cares about is the
    # timeout. Ports HttpResult#error_message and HttpResultHelpers.
    def self.classify_error(error : Exception, deadline_hit : Bool) : {ErrorKind, String}
      return {ErrorKind::Timeout, TIMEOUT_MESSAGE} if deadline_hit

      case error
      when OpenSSL::SSL::Error
        {ErrorKind::Tls, ssl_message(error.message)}
      when IO::TimeoutError
        {ErrorKind::Timeout, TIMEOUT_MESSAGE}
      when Socket::ConnectError
        {ErrorKind::ConnectionRefused, "Connection refused - target is not listening on this port"}
      when Socket::Addrinfo::Error
        {ErrorKind::Dns, "DNS resolution failed - could not resolve hostname"}
      when IO::Error
        io_message(error.message)
      else
        {ErrorKind::Other, error.message || error.class.name}
      end
    end

    # Maps an OpenSSL message to a friendly one by substring. Public so the
    # mapping table can be unit-tested without constructing an SSL handshake.
    def self.ssl_message(message : String?) : String
      down = message.to_s.downcase
      SSL_MESSAGES.each do |pattern, text|
        return text if down.includes?(pattern)
      end
      "SSL/TLS error: #{message}"
    end

    # Maps an IO error message to a closed-connection or generic I/O outcome.
    def self.io_message(message : String?) : {ErrorKind, String}
      down = message.to_s.downcase
      if down.includes?("closed") || down.includes?("broken pipe") || down.includes?("reset")
        {ErrorKind::Closed, "Connection closed unexpectedly - target may have dropped the connection"}
      else
        {ErrorKind::Io, "I/O error: #{message}"}
      end
    end
  end
end
