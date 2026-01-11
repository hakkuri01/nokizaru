# frozen_string_literal: true

require_relative 'version'
require_relative 'connection_pool'

module Nokizaru
  module HTTPClient
    module_function

    DEFAULT_HEADERS = {
      'User-Agent' => "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)",
      'Accept-Encoding' => 'gzip'
    }.freeze

    def build(timeout_s: 10.0, headers: {}, follow_redirects: true, persistent: true, verify_ssl: true)
      ConnectionPool.instance.client(
        headers: DEFAULT_HEADERS.merge(headers || {}),
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects,
        timeout_s: timeout_s.to_f
      )
    end

    # Get a persistent client optimized for a specific host.
    def for_host(origin, timeout_s: 10.0, headers: {}, follow_redirects: true, verify_ssl: true)
      base_client = ConnectionPool.instance.for_host(
        origin,
        headers: DEFAULT_HEADERS.merge(headers || {}),
        verify_ssl: verify_ssl,
        follow_redirects: follow_redirects
      )

      # Apply timeout override if needed
      if timeout_s && timeout_s != 10.0
        base_client.with(timeout: { operation_timeout: timeout_s.to_f })
      else
        base_client
      end
    end

    # Get a client optimized for bulk/parallel requests
    def for_bulk_requests(target, timeout_s: 8.0, headers: {}, follow_redirects: false,
                          verify_ssl: true, max_concurrent: 50)
      base_client = for_host(
        target,
        timeout_s: timeout_s,
        headers: headers.merge('Connection' => 'keep-alive'),
        follow_redirects: follow_redirects,
        verify_ssl: verify_ssl
      )

      # Override concurrency for bulk operations
      base_client.with(
        max_concurrent_requests: max_concurrent,
        timeout: {
          connect_timeout: 3.0,
          read_timeout: timeout_s.to_f,
          write_timeout: 3.0,
          operation_timeout: timeout_s.to_f
        }
      )
    end

    # Convenience method to make a single GET request.
    # Uses connection pooling automatically.
    def get(url, headers: {}, timeout_s: 10.0, verify_ssl: true)
      client = for_host(url, timeout_s: timeout_s, headers: headers, verify_ssl: verify_ssl)
      client.get(url)
    end

    # Shutdown all connections. Call this during application shutdown.
    def shutdown
      ConnectionPool.instance.shutdown
    end

    # Get connection pool statistics for debugging.
    def stats
      ConnectionPool.instance.stats
    end
  end
end
