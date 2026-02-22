# frozen_string_literal: true

require_relative 'version'
require_relative 'connection_pool'

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
end
