# frozen_string_literal: true

require_relative 'version'
require_relative 'connection_pool'
require_relative 'http_result_helpers'

module Nokizaru
  # Nokizaru::HTTPClient implementation
  module HTTPClient
    module_function

    DEFAULT_HEADERS = {
      'User-Agent' => "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)",
      'Accept-Encoding' => 'gzip'
    }.freeze

    # Build HTTP clients with shared defaults for reliability and performance
    def build(timeout_s: 10.0, headers: {}, follow_redirects: true, persistent: true, verify_ssl: true)
      ConnectionPool.instance.client(
        headers: DEFAULT_HEADERS.merge(headers || {}),
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects,
        persistent: persistent,
        timeout_s: timeout_s.to_f
      )
    end

    # Get a persistent client optimized for a specific host
    def for_host(origin, timeout_s: 10.0, headers: {}, follow_redirects: true, verify_ssl: true)
      base_client = ConnectionPool.instance.for_host(
        origin,
        headers: DEFAULT_HEADERS.merge(headers || {}),
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects
      )
      apply_operation_timeout(base_client, timeout_s)
    end

    def apply_operation_timeout(client, timeout_s)
      return client unless timeout_override?(timeout_s)

      client.with(timeout: { operation_timeout: timeout_s.to_f })
    end

    def timeout_override?(timeout_s)
      timeout_s && ((timeout_s.to_f - 10.0).abs > Float::EPSILON)
    end

    # Get a client optimized for bulk/parallel requests
    def for_bulk_requests(target, timeout_s: 8.0, headers: {}, **options)
      opts = default_bulk_options(timeout_s, options)
      base_client = for_host(
        target,
        timeout_s: timeout_s,
        headers: headers.merge('Connection' => 'keep-alive'),
        follow_redirects: opts[:follow_redirects],
        verify_ssl: opts[:verify_ssl]
      )

      base_client.with(**bulk_client_overrides(timeout_s, opts))
    end

    def default_bulk_options(timeout_s, options)
      {
        follow_redirects: false,
        verify_ssl: true,
        max_concurrent: 50,
        retries: nil,
        timeout_s: timeout_s.to_f
      }.merge(options || {})
    end

    def bulk_client_overrides(timeout_s, options)
      overrides = {
        max_concurrent_requests: options[:max_concurrent],
        timeout: bulk_timeout_profile(timeout_s)
      }
      retries = options[:retries]
      overrides[:max_retries] = [retries.to_i, 0].max unless retries.nil?
      overrides
    end

    def bulk_timeout_profile(timeout_s)
      {
        connect_timeout: 3.0,
        read_timeout: timeout_s.to_f,
        write_timeout: 3.0,
        operation_timeout: timeout_s.to_f
      }
    end

    # Convenience method to make a single GET request
    # Uses connection pooling automatically
    def get(url, headers: {}, timeout_s: 10.0, verify_ssl: true)
      client = for_host(url, timeout_s: timeout_s, headers: headers, verify_ssl: verify_ssl)
      client.get(url)
    end

    # Shutdown all connections. Call this during application shutdown
    def shutdown
      ConnectionPool.instance.shutdown
    end

    # Get connection pool statistics for debugging
    def stats
      ConnectionPool.instance.stats
    end
  end

  # Shared message catalogs for HTTP transport error normalization
  module HTTPErrorCatalog
    SSL_HINTS = {
      'wrong version number' => 'Try using HTTP instead of HTTPS',
      'record layer failure' => 'Try using HTTP instead of HTTPS',
      'certificate verify failed' => 'Use -s flag to disable SSL verification (testing only)'
    }.freeze

    SSL_MESSAGES = {
      'wrong version number' => 'SSL/TLS handshake failed - server may not support HTTPS on this port',
      'certificate verify failed' => 'SSL certificate verification failed - likely self-signed certificate',
      'tlsv1 alert' => 'SSL/TLS version mismatch - server requires different TLS version',
      'record layer failure' => 'SSL/TLS handshake failed - server does not support HTTPS on this port'
    }.freeze

    SIMPLE_MESSAGES = {
      Errno::ECONNREFUSED => 'Connection refused - target is not listening on this port',
      SocketError => 'DNS resolution failed - could not resolve hostname'
    }.freeze
  end

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
