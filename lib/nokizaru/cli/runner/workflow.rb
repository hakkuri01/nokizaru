# frozen_string_literal: true

require 'timeout'

module Nokizaru
  class CLI
    class Runner
      # Main scan execution flow and module dispatch
      module Workflow
        def run
          initialize_runtime!
          ensure_modules_selected!
          setup_run_context
          execute_modules(@enabled, @target, @info, @ctx)
          finalize_run!
        end

        private

        def setup_run_context
          @target = validated_target!
          @info = parse_target(@target)
          @workspace = build_workspace(@info)
          @cache = build_cache(@workspace)
          @start_time = Time.now
          @run = initial_run_payload(@target, @info, @start_time)
          @run_id = initialize_workspace_run(@workspace, @run)
          @ctx = Nokizaru::Context.new(
            run: @run,
            options: context_options(@opts, @info),
            workspace: @workspace,
            cache: @cache
          )
          @enabled = resolve_enabled_modules
        end

        def context_options(options, info)
          options.to_h.merge(request_headers: info[:request_headers])
        end

        def finalize_run!
          elapsed = finalize_run_timing(@run, @start_time)
          compute_findings!(@run)
          enrich_workspace_db!(@workspace, @run)
          handle_diff!(@workspace, @run_id, @run)
          @workspace.save_run(@run_id, @run) if @workspace && @run_id
          export_dir = export_if_enabled(@run, @info, @workspace, @run_id)
          print_run_completion(elapsed, @workspace, @run_id, export_dir)
          Log.write('-' * 30)
        end

        def ensure_modules_selected!
          module_flags = %i[full headers sslinfo whois crawl dns sub arch wayback ps dir]
          return if module_flags.any? { |key| @opts[key] }

          UI.line(:error, 'At least one argument is required. Try using --help')
          exit(1)
        end

        def execute_modules(enabled, target, info, ctx)
          Log.write('Starting full recon...') if @opts[:full]
          run_core_modules(enabled, target, info, ctx)
          run_optional_modules(enabled, target, info, ctx)
        end

        def run_core_modules(enabled, target, info, ctx)
          safe_run_module(:headers, enabled[:headers], ctx, timeout_s: module_timeout_s(info, :headers)) do
            Nokizaru::Modules::Headers.call(target, ctx)
          end
          safe_run_module(:sslinfo, enabled[:sslinfo], ctx, timeout_s: module_timeout_s(info, :sslinfo)) do
            Nokizaru::Modules::SSLInfo.call(info[:hostname], info[:ssl_port], ctx)
          end
          safe_run_module(:whois, enabled[:whois], ctx, timeout_s: module_timeout_s(info, :whois)) do
            Nokizaru::Modules::WhoisLookup.call(info[:domain], info[:suffix], ctx)
          end
          safe_run_module(:dns, enabled[:dns], ctx, timeout_s: module_timeout_s(info, :dns)) do
            Nokizaru::Modules::DNSEnumeration.call(info[:hostname], info[:dns_servers], ctx)
          end
          run_subdomains(enabled, info, ctx)
          run_architecture(enabled, target, info, ctx)
        end

        def run_optional_modules(enabled, target, info, ctx)
          safe_run_module(:ps, enabled[:ps], ctx, timeout_s: module_timeout_s(info, :ps)) do
            Nokizaru::Modules::PortScan.call(info[:ip], info[:pscan_threads], ctx)
          end
          safe_run_module(:crawl, enabled[:crawl], ctx) do
            Nokizaru::Modules::Crawler.call(target, info[:protocol], info[:netloc], ctx)
          end
          run_directory_enum(enabled, target, info, ctx)
          run_wayback(enabled, target, info, ctx)
        end

        def run_subdomains(enabled, info, ctx)
          return unless enabled[:sub]

          if info[:type_ip]
            UI.line(:error, 'Skipping Sub-Domain Enumeration : Not Supported for IP Addresses')
            exit(1) unless @opts[:full]
            return
          end
          return if info[:private_ip]

          safe_run_module(:sub, true, ctx, timeout_s: module_timeout_s(info, :sub)) do
            Nokizaru::Modules::Subdomains.call(info[:hostname], info[:timeout], ctx, info[:conf_path])
          end
        end

        def run_architecture(enabled, target, info, ctx)
          return unless enabled[:arch]

          safe_run_module(:arch, true, ctx, timeout_s: module_timeout_s(info, :arch)) do
            Nokizaru::Modules::ArchitectureFingerprinting.call(target, info[:timeout], ctx, info[:conf_path])
          end
        end

        def run_directory_enum(enabled, target, info, ctx)
          return unless enabled[:dir]

          safe_run_module(:dir, true, ctx) do
            Nokizaru::Modules::DirectoryEnum.call(
              target,
              info[:dir_threads],
              info[:timeout],
              info[:wordlist],
              info[:allow_redirects],
              info[:verify_ssl],
              info[:extensions],
              ctx,
              info[:request_headers]
            )
          end
        end

        def run_wayback(enabled, target, info, ctx)
          return unless enabled[:wayback]

          safe_run_module(:wayback, true, ctx, timeout_s: module_timeout_s(info, :wayback)) do
            Nokizaru::Modules::Wayback.call(target, ctx, timeout_s: [info[:timeout].to_f, 12.0].min,
                                                         raw: @opts[:wb_raw])
          end
        end

        def safe_run_module(key, enabled, ctx, timeout_s: nil, &block)
          return unless enabled

          timeout = timeout_s.to_f
          if timeout.positive?
            Timeout.timeout(timeout, &block)
          else
            yield
          end
        rescue Timeout::Error => e
          handle_module_failure(key, ctx, e, timeout_s: timeout)
        rescue StandardError => e
          handle_module_failure(key, ctx, e)
        end

        def handle_module_failure(key, ctx, error, timeout_s: nil)
          label = module_label(key)
          detail = timeout_s ? "timeout=#{format('%.1f', timeout_s)}s" : 'unbounded timeout'
          Log.write("[#{key}] Module failed (#{detail}) = #{error.class}: #{error.message}")

          existing = ctx.run['modules'][module_storage_key(key)]
          payload = existing.is_a?(Hash) ? existing.dup : {}
          payload.merge!({
                           'status' => 'failed',
                           'error' => "#{error.class}: #{error.message}",
                           'timed_out' => error.is_a?(Timeout::Error),
                           'module' => key.to_s,
                           'label' => label
                         })
          ctx.run['modules'][module_storage_key(key)] = payload
        end

        def module_timeout_s(info, key)
          base = info[:timeout].to_f
          return 0.0 if base <= 0

          case key.to_sym
          when :headers, :sslinfo, :whois
            [base * 3.0, 25.0].max
          when :dns
            [base * 4.0, 40.0].max
          when :sub, :arch
            [base * 5.0, 60.0].max
          when :ps
            [base * 6.0, 90.0].max
          when :wayback
            [base * 2.0, 24.0].max
          else
            0.0
          end
        end

        def module_label(key)
          {
            headers: 'Headers',
            sslinfo: 'SSL Certificate Information',
            whois: 'Whois Lookup',
            dns: 'DNS Enumeration',
            sub: 'Sub-Domain Enumeration',
            arch: 'Architecture Fingerprinting',
            ps: 'Port Scan',
            crawl: 'Crawler',
            dir: 'Directory Enum',
            wayback: 'WayBack Machine'
          }.fetch(key.to_sym, key.to_s)
        end

        def module_storage_key(key)
          {
            dir: 'directory_enum',
            sub: 'subdomains',
            ps: 'portscan'
          }.fetch(key.to_sym, key.to_s)
        end

        def resolve_enabled_modules
          order = %i[headers sslinfo whois dns sub arch ps crawl dir wayback]
          enabled = order.to_h { |mod| [mod, module_enabled?(mod)] }
          @skip.each { |mod, skip| enabled[mod] = false if skip }
          ensure_any_enabled!(enabled)
          enabled
        end

        def module_enabled?(mod)
          return true if @opts[:full]

          @opts[mod] == true
        end

        def ensure_any_enabled!(enabled)
          return if enabled.values.any?

          UI.line(:error, 'No Modules Specified! Use --full or a module flag')
          exit(1)
        end
      end
    end
  end
end
