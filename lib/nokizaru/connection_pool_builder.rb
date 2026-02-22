# frozen_string_literal: true

module Nokizaru
  # Helper methods for building HTTPX clients in ConnectionPool
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
      opts = { alpn_protocols: %w[http/1.1] }
      opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless verify_ssl
      opts
    end
  end
end
