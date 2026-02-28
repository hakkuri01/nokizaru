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

        PROVIDER_NAMES = %w[
          AnubisDB ThreatMiner CertSpotter HackerTarget crt.sh UrlScan AlienVault
          BeVigil Facebook VirusTotal Shodan BinaryEdge ZoomEye Netlas Hunter Chaos Censys
        ].freeze

        PROVIDER_ALIASES = {
          'binedge' => 'BinaryEdge'
        }.freeze

        OUTPUT_GROUP_ORDER = %i[requesting status_info skipping status_error exception found].freeze

        # Print provider request start message
        def requesting(name)
          emit_or_print(:requesting, name, nil)
        end

        # Print provider success summary
        def found(name, count)
          emit_or_print(:found, name, count)
        end

        # Print provider error status
        def status_error(name, status, reason = '')
          emit_or_print(:status_error, name, { status: status, reason: reason })
        end

        # Print provider status line without error context
        def status_info(name, status)
          emit_or_print(:status_info, name, status)
        end

        # Print provider exception
        def exception(name, error)
          emit_or_print(:exception, name, error)
        end

        # Print provider skip reason
        def skipping(name, reason)
          emit_or_print(:skipping, name, reason)
        end

        def start_output_capture(provider_names = nil)
          synchronize_events do
            @subdomain_events = []
            @subdomain_event_seq = 0
            @capture_enabled = true
            @provider_order = build_provider_order(provider_names)
          end
        end

        def flush_output_capture
          events, provider_order = synchronize_events do
            [Array(@subdomain_events).dup, @provider_order || build_provider_order(PROVIDER_NAMES)]
          end
          return if events.empty?

          OUTPUT_GROUP_ORDER.each do |kind|
            grouped = events.select { |event| event[:kind] == kind }
            grouped.sort_by! { |event| [provider_order.fetch(event[:name].to_s.downcase, 999), event[:seq]] }
            grouped.each { |event| print_event(event) }
          end
        end

        def stop_output_capture
          synchronize_events do
            @capture_enabled = false
            @subdomain_events = []
            @provider_order = build_provider_order(PROVIDER_NAMES)
          end
        end

        def output_capture_enabled?
          synchronize_events { !!@capture_enabled }
        end

        def emit_or_print(kind, name, payload)
          normalized_name = display_provider_name(name)
          return print_event(kind: kind, name: normalized_name, payload: payload) unless output_capture_enabled?

          synchronize_events do
            @subdomain_event_seq ||= 0
            @subdomain_events ||= []
            @subdomain_event_seq += 1
            @subdomain_events << { kind: kind, name: normalized_name, payload: payload, seq: @subdomain_event_seq }
          end
        end

        def print_event(event)
          kind = event[:kind].to_sym
          name = event[:name].to_s
          payload = event[:payload]

          case kind
          when :requesting
            UI.row(:plus, 'Requesting', name, label_width: subdomain_label_width)
          when :skipping
            UI.row(:error, "Skipping #{name}", payload, label_width: subdomain_label_width)
          when :status_info
            UI.row(:info, "#{name} Status", payload, label_width: subdomain_label_width)
          when :status_error
            print_status_event(name, payload)
          when :exception
            UI.row(:error, "#{name} Exception", payload, label_width: subdomain_label_width)
          when :found
            UI.row(:info, "#{name} Results", "#{payload} subdomains", label_width: subdomain_label_width)
          end
        end

        def print_status_event(name, payload)
          status = payload.is_a?(Hash) ? payload[:status] : payload
          reason = payload.is_a?(Hash) ? payload[:reason] : ''
          value = formatted_status_value(status, reason)
          UI.row(:error, "#{name} Status", value, label_width: subdomain_label_width)
        end

        def formatted_status_value(status, reason)
          status_text = status.to_s.strip
          reason_text = reason.to_s.strip
          return status_text if reason_text.empty?
          return reason_text if reason_text.casecmp?("HTTP Error: #{status_text}")

          "#{status_text} (#{reason_text})"
        end

        def build_provider_order(provider_names)
          Array(provider_names).each_with_index.to_h { |provider, idx| [provider.to_s.downcase, idx] }
        end

        def display_provider_name(name)
          value = name.to_s
          return value if value.empty?

          aliased = PROVIDER_ALIASES[value.downcase]
          return aliased if aliased

          PROVIDER_NAMES.find { |provider| provider.casecmp?(value) } || value
        end

        def synchronize_events(&)
          @events_mutex ||= Mutex.new
          @events_mutex.synchronize(&)
        end

        def subdomain_label_width
          @subdomain_label_width ||= begin
            labels = PROVIDER_NAMES.flat_map do |name|
              [
                "#{name} Results",
                "#{name} Status",
                "#{name} Exception",
                "Skipping #{name}"
              ]
            end
            labels << 'Requesting'
            labels.map(&:length).max
          end
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
