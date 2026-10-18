# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # What the dashboard shows about a planned run, read after plan! and while the scan runs
      module Profile
        # Flags shown on the Modules row or not at all, never on the Switches row
        NON_SWITCHES = %i[target full headers sslinfo whois crawl dns sub arch dir wayback ps k].freeze
        LONG_SWITCHES = %i[export].freeze

        attr_reader :progress_rail

        def tui_profile
          {
            target: @target,
            ip: @info[:ip] || "unresolved (#{@info[:ip_resolution_error]})",
            modules: modules_summary,
            switches: switches_summary,
            notice: target_notice,
            modules_enabled: enabled_module_keys(@enabled)
          }
        end

        def module_statuses
          stored = @ctx.run['modules']
          enabled_module_keys(@enabled).to_h do |key|
            entry = stored[module_storage_key(key)]
            [key, entry.is_a?(Hash) ? entry['status'].to_s : '']
          end
        end

        private

        def modules_summary
          selected = @opts[:full] ? ['full'] : Workflow::MODULE_ORDER.select { |key| @opts[key] }.map(&:to_s)
          skipped = @skip.select { |_, skip| skip }.keys.map { |key| "no-#{key}" }
          (selected + skipped).join('  ')
        end

        def switches_summary
          parts = CLIOptions::OPTION_DEFS.keys.filter_map { |key| switch_text(key) unless NON_SWITCHES.include?(key) }
          parts.empty? ? 'none' : parts.join('  ')
        end

        # Security: request header values can carry session cookies, so only their count is ever shown
        def switch_text(key)
          return header_switch if key == :header

          value = @opts[key]
          return nil if value.nil? || value == false

          flag = LONG_SWITCHES.include?(key) ? "--#{key}" : "-#{key}"
          value == true ? flag : "#{flag} #{value}"
        end

        def header_switch
          count = @info[:request_headers].to_h.length
          "-H ×#{count}" if count.positive?
        end

        def target_notice
          uri = URI.parse(@target)
          return nil unless uri.port && unusual_scheme_port?(uri.scheme.to_s, uri.port)

          "Using #{uri.scheme} with port #{uri.port}"
        end
      end
    end
  end
end
