# frozen_string_literal: true

require 'httpx'

begin
  require 'httpx/plugins/follow_redirects'
rescue LoadError
  # Optional
end

begin
  require 'httpx/plugins/persistent'
rescue LoadError
  # Optional
end

begin
  require 'openssl'
rescue LoadError
  # Optional
end

module Nokizaru
  # Centralized HTTP client builder.
  #
  # Goals:
  # - Consistent performance by enforcing tight connect/read/overall timeouts.
  # - Avoid per-request options that can be slow or incompatible across HTTPX versions.
  # - Reuse connections when possible (persistent).
  module HTTPClient
    module_function

    DEFAULT_HEADERS = {
      'User-Agent' => "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)",
      'Accept-Encoding' => 'gzip'
    }.freeze

    # Build a configured HTTPX client.
    #
    # timeout_s is treated as a hard budget for the request operation.
    def build(timeout_s: 10.0, headers: {}, follow_redirects: true, persistent: true, verify_ssl: true)
      http = HTTPX

      if follow_redirects
        begin
          http = http.plugin(:follow_redirects)
        rescue StandardError
          # ignore
        end
      end

      if persistent
        begin
          http = http.plugin(:persistent)
        rescue StandardError
          # ignore
        end
      end

      # HTTPX supports granular timeouts; use them when available.
      t = timeout_s.to_f
      # Keep connect small: if can't connect quickly, move on.
      connect_t = [5.0, t].min
      read_t    = [t, 12.0].min

      opts = {
        headers: DEFAULT_HEADERS.merge(headers || {}),
        timeout: {
          connect_timeout: connect_t,
          read_timeout: read_t,
          write_timeout: connect_t,
          operation_timeout: t
        }
      }

      # Prefer client-level SSL verify control (avoid per-request verify option).
      if !verify_ssl && defined?(OpenSSL)
        begin
          opts[:ssl] = { verify_mode: OpenSSL::SSL::VERIFY_NONE }
        rescue StandardError
          # ignore
        end
      end

      http.with(**opts)
    rescue StandardError
      HTTPX.with(timeout: { operation_timeout: timeout_s.to_f })
    end
  end
end
