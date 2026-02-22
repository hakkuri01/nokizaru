# frozen_string_literal: true

require_relative 'http_error_catalog'
require_relative 'http_result_helpers'

module Nokizaru
  # Wrapper class for consistent HTTP response handling
  # Safely handles both successful responses and HTTPX::ErrorResponse objects
  class HttpResult
    include HttpResultHelpers

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

      ssl_message = ssl_error_message
      return ssl_message if ssl_message

      mapped_message = mapped_error_message
      return mapped_message if mapped_message

      fallback_error_message
    end

    # Returns a short hint for how to fix the error
    def error_hint
      return nil if success?

      ssl_hint = ssl_error_hint
      return ssl_hint if ssl_hint

      mapped_hint = mapped_error_hint
      return mapped_hint if mapped_hint

      io_descriptor_hint || descriptor_hint
    end

    private

    def ssl_error_message
      return nil unless @error.is_a?(OpenSSL::SSL::SSLError)

      parse_ssl_error(@error)
    end

    def mapped_error_message
      return handle_io_error(@error) if @error.is_a?(IOError) || @error.is_a?(Errno::EPIPE)
      return 'Connection timeout - target took too long to respond' if timeout_error?
      return "HTTP error: #{@error.message}" if @error.is_a?(HTTPX::HTTPError)

      Nokizaru::HTTPErrorCatalog::SIMPLE_MESSAGES.each do |klass, message|
        return message if @error.is_a?(klass)
      end
      nil
    end

    def fallback_error_message
      descriptor_message || @error.message
    end

    def ssl_error_hint
      return nil unless @error.is_a?(OpenSSL::SSL::SSLError)

      message = @error.message.to_s
      Nokizaru::HTTPErrorCatalog::SSL_HINTS.each do |pattern, hint|
        return hint if message.include?(pattern)
      end
      nil
    end

    def mapped_error_hint
      case @error
      when Errno::ECONNREFUSED
        'Check if the target service is running'
      when Errno::ETIMEDOUT
        'Try increasing timeout with -T option'
      end
    end
  end
end
