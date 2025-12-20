# frozen_string_literal: true

require_relative '../../log'
require_relative '../../keys'

module Nokizaru
  module Modules
    module SubdomainModules
      # Shared helpers for subdomain source modules.
      module Base
        module_function

        R = "\e[31m"
        G = "\e[32m"
        C = "\e[36m"
        W = "\e[0m"
        Y = "\e[33m"

        # HTTPX may return an HTTPX::ErrorResponse on network failures.
        # Those objects do not always implement the same surface (e.g. #status).
        # Keep subdomain modules resilient by using these helpers.
        def safe_status(resp)
          return resp.status if resp&.respond_to?(:status)

          nil
        end

        # Prefer the response body; avoid dumping large debug structures for HTTPX error responses.
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
          # Heuristic: some HTTPX error responses stringify to an inspected object-like representation.
          return '' if s.include?('HTTPX::') || s.include?('headers=>') || s.start_with?('#<')

          s
        rescue StandardError
          ''
        end

        def body_snippet(resp, max: 220)
          s = safe_body(resp).to_s.strip
          return '' if s.empty?

          s = s.gsub(/\s+/, ' ')
          s.length > max ? (s[0, max] + '…') : s
        rescue StandardError
          ''
        end

        # Human-readable reason for HTTPX failures (ErrorResponse etc.).
        # Returns empty string when no details are available.
        def failure_reason(resp)
          return '' unless resp

          if resp.respond_to?(:error) && (err = resp.error)
            # HTTPX error strings can be *very* noisy, often embedding headers hashes
            # and sometimes an entire HTML page. Keep this short and human-readable.
            s = err.to_s.to_s
            # Common pattern: "HTTP Error: 500 { ...headers hash... }".
            s = s.split(' {', 2).first if s.include?(' {')
            # Some builds wrap extra details in parentheses.
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

        # Render a consistent FinalRecon-style status line, without dumping headers or objects.
        def print_status(vendor, resp)
          st = status_label(resp)
          reason = failure_reason(resp)
          suffix = reason.empty? ? '' : " (#{reason})"
          puts("#{R}[-] #{C}#{vendor} Status : #{W}#{st}#{suffix}")
        end

        def status_label(resp)
          st = safe_status(resp)
          st ? st.to_s : 'ERR'
        end

        # Centralized key lookup (kept for signature parity with upstream).
        def ensure_key(name, _conf_path, env)
          KeyStore.fetch(name, env: env)
        end
      end
    end
  end
end
