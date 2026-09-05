# frozen_string_literal: true

require_relative '../../log'
require_relative '../../keys'
require_relative '../../http_client'

module Nokizaru
  module Modules
    module SubdomainModules
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

        def requesting(name)
          emit_or_print(:requesting, name, nil)
        end

        def found(name, count)
          emit_or_print(:found, name, count)
        end

        def status_error(name, status, reason = '')
          emit_or_print(:status_error, name, { status: status, reason: reason })
        end

        def status_info(name, status)
          emit_or_print(:status_info, name, status)
        end

        def exception(name, error)
          emit_or_print(:exception, name, error)
        end

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

        def safe_status(resp)
          return resp.status if resp.respond_to?(:status)

          nil
        end

        def safe_body(resp)
          return '' unless resp

          body = extract_body(resp)
          return body unless body.empty?

          fallback_body(resp)
        rescue StandardError
          ''
        end

        def extract_body(resp)
          return '' unless resp.respond_to?(:body)

          value = resp.body
          value ? value.to_s : ''
        end

        def fallback_body(resp)
          return '' unless resp.respond_to?(:to_s)

          value = resp.to_s
          return '' if value.include?('HTTPX::') || value.include?('headers=>') || value.start_with?('#<')

          value
        end

        def body_snippet(resp, max: 220)
          normalized = safe_body(resp).to_s.strip.gsub(/\s+/, ' ')
          return '' if normalized.empty?

          normalized.length > max ? "#{normalized[0, max]}…" : normalized
        rescue StandardError
          ''
        end

        def failure_reason(resp)
          return '' unless resp
          return resp.error? ? resp.error_message : '' if resp.is_a?(HttpResult)
          return error_reason(resp.error) if resp.respond_to?(:error) && resp.error
          return resp.exception.to_s.strip if resp.respond_to?(:exception) && resp.exception

          body_snippet(resp)
        rescue StandardError
          ''
        end

        def error_reason(error)
          message = error.to_s
          message = message.split(' {', 2).first if message.include?(' {')
          message = message.split(' (', 2).first if message.start_with?('HTTP Error:') && message.include?(' (')
          message.strip
        end

        def print_status(vendor, resp)
          if resp.is_a?(HttpResult)
            return status_info(vendor, resp.status) if resp.success?

            return status_error(vendor, resp.status || 'ERR', resp.error_message)
          end

          status_error(vendor, status_label(resp), failure_reason(resp))
        end

        def status_label(resp)
          status = safe_status(resp)
          status ? status.to_s : 'ERR'
        end

        def ensure_key(name, env)
          KeyStore.fetch(name, env: env)
        end
      end
    end
  end
end
