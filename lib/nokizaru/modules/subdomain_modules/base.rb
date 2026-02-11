# frozen_string_literal: true

require_relative '../../log'
require_relative '../../keys'
require_relative '../../http_result'

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
          return resp.status if resp&.respond_to?(:status)

          nil
        end

        # Legacy helper - maintained for backward compatibility
        # New code should use HttpResult#body directly
        def safe_body(resp)
          return '' unless resp

          if resp.respond_to?(:body)
            b = resp.body
            bs = b.to_s if b
            return bs if bs && !bs.empty?
          end

          s = resp.to_s if resp.respond_to?(:to_s)
          return '' unless s

          s = s.to_s
          # Heuristic: some HTTPX error responses stringify to an inspected object-like representation
          return '' if s.include?('HTTPX::') || s.include?('headers=>') || s.start_with?('#<')

          s
        rescue StandardError
          ''
        end

        # Create a compact body preview for readable error messages
        def body_snippet(resp, max: 220)
          s = safe_body(resp).to_s.strip
          return '' if s.empty?

          s = s.gsub(/\s+/, ' ')
          s.length > max ? (s[0, max] + '…') : s
        rescue StandardError
          ''
        end

        # Human-readable reason for HTTPX failures
        # Works with both raw responses and HttpResult objects
        def failure_reason(resp)
          return '' unless resp

          # If it's an HttpResult, use its error_message
          if resp.is_a?(HttpResult)
            return resp.error? ? resp.error_message : ''
          end

          # Legacy handling for raw HTTPX responses
          if resp.respond_to?(:error) && (err = resp.error)
            s = err.to_s.to_s
            # Common pattern: "HTTP Error: 500 { ...headers hash... }"
            s = s.split(' {', 2).first if s.include?(' {')
            s = s.split(' (', 2).first if s.start_with?('HTTP Error:') && s.include?(' (')
            s.strip
          elsif resp.respond_to?(:exception) && (exc = resp.exception)
            exc.to_s.to_s.strip
          else
            body_snippet(resp)
          end
        rescue StandardError
          ''
        end

        # Print status with improved formatting
        # Works with both raw responses and HttpResult objects
        def print_status(vendor, resp)
          if resp.is_a?(HttpResult)
            if resp.success?
              UI.line(:info, "#{vendor} Status : #{resp.status}")
            else
              st = resp.status || 'ERR'
              reason = resp.error_message
              status_error(vendor, st, reason)
            end
          else
            # Legacy handling
            st = status_label(resp)
            reason = failure_reason(resp)
            status_error(vendor, st, reason)
          end
        end

        # Build a stable status label for provider logs and terminal output
        def status_label(resp)
          st = safe_status(resp)
          st ? st.to_s : 'ERR'
        end

        # Centralized key lookup
        def ensure_key(name, _conf_path, env)
          KeyStore.fetch(name, env: env)
        end

        # Make HTTP request and return HttpResult
        # Provides a consistent interface for all subdomain modules
        def fetch_with_result(client, url, **options)
          raw_response = client.get(url, **options)
          HttpResult.new(raw_response)
        rescue StandardError => e
          # Create a fake error response for consistency
          error_response = Object.new
          error_response.define_singleton_method(:error) { e }
          error_response.instance_variable_set(:@is_error, true)

          class << error_response
            # Mark the synthetic error object as compatible with HTTPX::ErrorResponse
            def is_a?(klass)
              return true if klass == HTTPX::ErrorResponse

              super
            end
          end

          HttpResult.new(error_response)
        end
      end
    end
  end
end
