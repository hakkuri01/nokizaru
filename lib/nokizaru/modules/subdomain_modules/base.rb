# frozen_string_literal: true

require_relative '../../log'
require_relative '../../keys'
require_relative '../../http_result'
require_relative 'base_legacy'
require_relative 'base_http'

module Nokizaru
  module Modules
    module SubdomainModules
      # Shared helpers for subdomain source modules
      module Base
        module_function

        # Print provider request start message
        def requesting(name)
          UI.line(:plus, "Requesting #{name}")
        end

        # Print provider success summary
        def found(name, count)
          UI.line(:info, "#{name} found #{count} subdomains!")
        end

        # Print provider error status
        def status_error(name, status, reason = '')
          suffix = reason.to_s.strip.empty? ? '' : " (#{reason})"
          UI.line(:error, "#{name} Status : #{status}#{suffix}")
        end

        # Print provider exception
        def exception(name, error)
          UI.line(:error, "#{name} Exception : #{error}")
        end

        # Print provider skip reason
        def skipping(name, reason)
          UI.line(:error, "Skipping #{name} : #{reason}")
        end

        # Wrap raw HTTPX response in HttpResult for consistent handling
        def wrap_response(raw_response)
          HttpResult.new(raw_response)
        end

        # Legacy helper - maintained for backward compatibility
        # New code should use HttpResult directly
        def safe_status(resp)
          BaseLegacy.safe_status(resp)
        end

        # Legacy helper - maintained for backward compatibility
        # New code should use HttpResult#body directly
        def safe_body(resp)
          BaseLegacy.safe_body(resp)
        end

        # Create a compact body preview for readable error messages
        def body_snippet(resp, max: 220)
          BaseLegacy.body_snippet(resp, max: max)
        end

        # Human-readable reason for HTTPX failures
        # Works with both raw responses and HttpResult objects
        def failure_reason(resp)
          BaseLegacy.failure_reason(resp)
        end

        # Print status with improved formatting
        # Works with both raw responses and HttpResult objects
        def print_status(vendor, resp)
          BaseLegacy.print_status(vendor, resp)
        end

        # Build a stable status label for provider logs and terminal output
        def status_label(resp)
          BaseLegacy.status_label(resp)
        end

        # Centralized key lookup
        def ensure_key(name, _conf_path, env)
          KeyStore.fetch(name, env: env)
        end

        # Make HTTP request and return HttpResult
        # Provides a consistent interface for all subdomain modules
        def fetch_with_result(client, url, **options)
          BaseHTTP.fetch_with_result(client, url, **options)
        end
      end
    end
  end
end
