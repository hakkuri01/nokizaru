# frozen_string_literal: true

module Nokizaru
  # Wrapper class for consistent HTTP response handling
  # Safely handles both successful responses and HTTPX::ErrorResponse objects
  class HttpResult
    attr_reader :response, :error

    # Capture runtime options and prepare shared state used by this object
    def initialize(response)
      @response = response
      @is_error = response.is_a?(HTTPX::ErrorResponse)
      @error = @is_error ? response.error : nil
    end

    # Report whether the HTTP response is successful for module logic
    def success?
      !@is_error
    end

    # Report whether the HTTP response represents an error case
    def error?
      @is_error
    end

    # Expose response headers in a normalized hash shape
    def headers
      success? ? @response.headers : {}
    end

    # Expose response body text for parsing and error diagnostics
    def body
      success? ? @response.body.to_s : nil
    end

    # Expose response status code across success and error wrappers
    def status
      success? ? @response.status : nil
    end

    # Returns a user-friendly error message with actionable suggestions
    def error_message
      return nil if success?

      case @error
      when OpenSSL::SSL::SSLError
        parse_ssl_error(@error)
      when Errno::ECONNREFUSED
        'Connection refused - target is not listening on this port'
      when Errno::ETIMEDOUT, Timeout::Error
        'Connection timeout - target took too long to respond'
      when SocketError
        'DNS resolution failed - could not resolve hostname'
      when HTTPX::HTTPError
        "HTTP error: #{@error.message}"
      when IOError, Errno::EPIPE
        handle_io_error(@error)
      else
        # Check if error message contains common patterns
        msg = @error.message.to_s
        if msg.include?('descriptor closed') || msg.include?('Broken pipe')
          'Connection closed unexpectedly - target may have dropped the connection'
        else
          @error.message
        end
      end
    end

    # Returns a short hint for how to fix the error
    def error_hint
      return nil if success?

      case @error
      when OpenSSL::SSL::SSLError
        if @error.message.include?('wrong version number') || @error.message.include?('record layer failure')
          'Try using HTTP instead of HTTPS'
        elsif @error.message.include?('certificate verify failed')
          'Use -s flag to disable SSL verification (testing only)'
        end
      when Errno::ECONNREFUSED
        'Check if the target service is running'
      when Errno::ETIMEDOUT
        'Try increasing timeout with -T option'
      when IOError
        msg = @error.message.to_s
        'Try using HTTP instead of HTTPS' if msg.include?('descriptor closed') || msg.include?('closed stream')
      else
        # Check message patterns for descriptor/connection issues
        msg = @error.message.to_s
        'Try using HTTP instead of HTTPS' if msg.include?('descriptor closed') || msg.include?('Broken pipe')
      end
    end

    private

    # Parse SSL exceptions into readable reasons for operators
    def parse_ssl_error(error)
      msg = error.message

      if msg.include?('wrong version number')
        'SSL/TLS handshake failed - server may not support HTTPS on this port'
      elsif msg.include?('certificate verify failed')
        'SSL certificate verification failed - likely self-signed certificate'
      elsif msg.include?('tlsv1 alert')
        'SSL/TLS version mismatch - server requires different TLS version'
      elsif msg.include?('record layer failure')
        'SSL/TLS handshake failed - server does not support HTTPS on this port'
      else
        "SSL/TLS error: #{msg}"
      end
    end

    # Detect common IO failures and classify them for clearer error reporting
    def handle_io_error(error)
      msg = error.message.to_s
      if msg.include?('closed stream') || msg.include?('descriptor')
        'Connection closed by server - target may not support HTTPS or dropped the connection'
      elsif msg.include?('Broken pipe')
        'Connection reset - target closed the connection unexpectedly'
      else
        "I/O error: #{msg}"
      end
    end
  end
end
