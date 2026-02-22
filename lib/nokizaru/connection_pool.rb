# frozen_string_literal: true

require 'httpx'
require 'monitor'
require_relative 'version'
require_relative 'connection_pool_builder'

# Load HTTPX plugins
%w[follow_redirects persistent retries].each do |plugin|
  require "httpx/plugins/#{plugin}"
rescue LoadError
  # Optional plugin
end

begin
  require 'openssl'
rescue StandardError
  nil
end

module Nokizaru
  # Nokizaru::ConnectionPool implementation
  class ConnectionPool
    include MonitorMixin
    include ConnectionPoolBuilder

    DEFAULT_CONFIG = {
      connect_timeout: 5.0,
      read_timeout: 15.0,
      write_timeout: 5.0,
      operation_timeout: 30.0,
      keep_alive_timeout: 30,
      retries: 2
    }.freeze

    DEFAULT_HEADERS = {
      'User-Agent' => "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)",
      'Accept-Encoding' => 'gzip, deflate',
      'Accept' => '*/*',
      'Connection' => 'keep-alive'
    }.freeze

    class << self
      # Return a shared pool instance so modules reuse persistent connections
      def instance
        @instance ||= new
      end

      # Reset the shared pool instance for tests and controlled reinitialization
      def reset!
        @instance&.shutdown
        @instance = nil
      end
    end

    # Capture constructor arguments and initialize internal state
    def initialize
      super
      @pools = {}
      @config = DEFAULT_CONFIG.dup
    end

    # Build pool settings with safe defaults for scanner workloads
    def configure(**options)
      synchronize do
        @config.merge!(options)
        @pools.clear
      end
    end

    # Get a persistent client for the given origin
    def for_host(origin, headers: {}, verify_ssl: true, follow_redirects: true)
      uri = URI.parse(origin)
      port = uri.port || (uri.scheme == 'https' ? 443 : 80)
      cache_key = "#{uri.scheme}://#{uri.host}:#{port}:ssl=#{verify_ssl}:redir=#{follow_redirects}"

      synchronize do
        @pools[cache_key] ||= build_client(
          headers: headers,
          verify_ssl: verify_ssl,
          follow_redirects: follow_redirects
        )
      end
    end

    # Get a fresh client (not cached)
    def client(headers: {}, verify_ssl: true, follow_redirects: true, persistent: true, timeout_s: nil)
      build_client(
        headers: headers,
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects,
        persistent: persistent,
        timeout_s: timeout_s
      )
    end

    # Close pooled clients cleanly so scans exit without leaked resources
    def shutdown
      synchronize do
        @pools.each_value do |c|
          c.close
        rescue StandardError
          nil
        end
        @pools.clear
      end
    end

    # Return lightweight pool metrics for diagnostics and troubleshooting
    def stats
      synchronize { { pool_count: @pools.size, pools: @pools.keys } }
    end

    private

    # Build an HTTP client with pooling and safe defaults for scanner modules
    def build_client(headers: {}, verify_ssl: true, follow_redirects: true, persistent: true, timeout_s: nil)
      http = apply_plugins(HTTPX, persistent: persistent, follow_redirects: follow_redirects)
      op_timeout = timeout_s || @config[:operation_timeout]

      http.with(**build_client_options(headers, op_timeout, persistent, verify_ssl))
    rescue StandardError => e
      warn "[ConnectionPool] Warning: #{e.message}, using fallback client"
      fallback_client(headers, timeout_s)
    end

    # Build a minimal fallback client when advanced pooling is unavailable
    def fallback_client(headers, timeout_s)
      HTTPX.with(
        headers: DEFAULT_HEADERS.merge(headers),
        timeout: { operation_timeout: timeout_s || 30.0 },
        ssl: { alpn_protocols: %w[http/1.1] }
      )
    end
  end
end
