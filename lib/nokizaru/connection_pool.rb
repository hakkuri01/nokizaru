# frozen_string_literal: true

require 'httpx'
require 'monitor'
require_relative 'version'

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
  class ConnectionPool
    include MonitorMixin

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
      def instance
        @instance ||= new
      end

      def reset!
        @instance&.shutdown
        @instance = nil
      end
    end

    def initialize
      super()
      @pools = {}
      @config = DEFAULT_CONFIG.dup
    end

    def configure(**options)
      synchronize do
        @config.merge!(options)
        @pools.clear
      end
    end

    # Get a persistent client for the given origin.
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

    # Get a fresh client (not cached).
    def client(headers: {}, verify_ssl: true, follow_redirects: true, timeout_s: nil)
      build_client(
        headers: headers,
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects,
        timeout_s: timeout_s
      )
    end

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

    def stats
      synchronize { { pool_count: @pools.size, pools: @pools.keys } }
    end

    private

    def build_client(headers: {}, verify_ssl: true, follow_redirects: true, timeout_s: nil)
      http = HTTPX

      # Load plugins safely
      http = begin
        http.plugin(:persistent)
      rescue StandardError
        http
      end
      if follow_redirects
        http = begin
          http.plugin(:follow_redirects)
        rescue StandardError
          http
        end
      end
      http = begin
        http.plugin(:retries)
      rescue StandardError
        http
      end

      op_timeout = timeout_s || @config[:operation_timeout]

      opts = {
        headers: DEFAULT_HEADERS.merge(headers),
        timeout: {
          connect_timeout: [@config[:connect_timeout], op_timeout].min,
          read_timeout: [@config[:read_timeout], op_timeout].min,
          write_timeout: [@config[:write_timeout], op_timeout].min,
          operation_timeout: op_timeout,
          keep_alive_timeout: @config[:keep_alive_timeout]
        },
        persistent: true,
        max_retries: @config[:retries]
      }

      # Force HTTP/1.1 via ALPN to avoid HTTP/2 protocol errors.
      ssl_opts = { alpn_protocols: %w[http/1.1] }
      ssl_opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless verify_ssl
      opts[:ssl] = ssl_opts

      http.with(**opts)
    rescue StandardError => e
      warn "[ConnectionPool] Warning: #{e.message}, using fallback client"
      fallback_client(headers, timeout_s)
    end

    def fallback_client(headers, timeout_s)
      HTTPX.with(
        headers: DEFAULT_HEADERS.merge(headers),
        timeout: { operation_timeout: timeout_s || 30.0 },
        ssl: { alpn_protocols: %w[http/1.1] }
      )
    end
  end
end
