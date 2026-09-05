# frozen_string_literal: true

require 'httpx'
require 'digest'
require 'monitor'
require_relative 'version'

%w[follow_redirects persistent retries].each do |plugin|
  require "httpx/plugins/#{plugin}"
rescue LoadError
  # HTTPX plugins are optional across supported installations
end

begin
  require 'openssl'
rescue StandardError
  nil
end

module Nokizaru
  module ConnectionPoolBuilder
    private

    def apply_plugins(http, persistent:, follow_redirects:)
      client = plugin_if_available(http, :persistent, enabled: persistent)
      client = plugin_if_available(client, :follow_redirects, enabled: follow_redirects)
      plugin_if_available(client, :retries, enabled: true)
    end

    def plugin_if_available(http, plugin, enabled: true)
      return http unless enabled

      http.plugin(plugin)
    rescue StandardError
      http
    end

    def build_client_options(headers, op_timeout, persistent, verify_ssl)
      {
        headers: self.class::DEFAULT_HEADERS.merge(headers),
        timeout: timeout_options(op_timeout),
        persistent: persistent,
        max_retries: @config[:retries],
        ssl: ssl_options(verify_ssl)
      }
    end

    def timeout_options(op_timeout)
      {
        connect_timeout: [@config[:connect_timeout], op_timeout].min,
        read_timeout: [@config[:read_timeout], op_timeout].min,
        write_timeout: [@config[:write_timeout], op_timeout].min,
        operation_timeout: op_timeout,
        keep_alive_timeout: @config[:keep_alive_timeout]
      }
    end

    def ssl_options(verify_ssl)
      opts = {}
      opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless verify_ssl
      opts
    end
  end

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
      'Accept' => '*/*'
    }.freeze

    class << self
      # Return a shared pool instance so modules reuse persistent connections
      def instance
        @instance ||= new
      end
    end

    def initialize
      super
      @pools = {}
      @config = DEFAULT_CONFIG.dup
    end

    def for_host(origin, headers: {}, verify_ssl: true, follow_redirects: true)
      uri = URI.parse(origin)
      port = uri.port || (uri.scheme == 'https' ? 443 : 80)
      cache_key = [
        "#{uri.scheme}://#{uri.host}:#{port}",
        "ssl=#{verify_ssl}",
        "redir=#{follow_redirects}",
        "headers=#{headers_cache_key(headers)}"
      ].join(':')

      synchronize do
        @pools[cache_key] ||= build_client(
          headers: headers,
          verify_ssl: verify_ssl,
          follow_redirects: follow_redirects
        )
      end
    end

    def client(headers: {}, verify_ssl: true, follow_redirects: true, persistent: true, timeout_s: nil)
      build_client(
        headers: headers,
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects,
        persistent: persistent,
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

    private

    def build_client(headers: {}, verify_ssl: true, follow_redirects: true, persistent: true, timeout_s: nil)
      http = apply_plugins(HTTPX, persistent: persistent, follow_redirects: follow_redirects)
      op_timeout = timeout_s || @config[:operation_timeout]

      http.with(**build_client_options(headers, op_timeout, persistent, verify_ssl))
    rescue StandardError => e
      warn "[ConnectionPool] Warning: #{e.message}, using fallback client"
      fallback_client(headers, timeout_s, verify_ssl)
    end

    # Build a minimal fallback client when advanced pooling is unavailable
    def fallback_client(headers, timeout_s, verify_ssl)
      HTTPX.with(
        headers: DEFAULT_HEADERS.merge(headers),
        timeout: { operation_timeout: timeout_s || 30.0 },
        ssl: ssl_options(verify_ssl)
      )
    end

    def headers_cache_key(headers)
      normalized = (headers || {})
                   .sort_by { |key, _value| key.to_s.downcase }
                   .map { |key, value| [key.to_s, value.to_s] }
      Digest::SHA256.hexdigest(Marshal.dump(normalized))[0, 16]
    end
  end
end
