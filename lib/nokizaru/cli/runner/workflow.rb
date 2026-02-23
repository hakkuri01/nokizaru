# frozen_string_literal: true

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
          @ctx = Nokizaru::Context.new(run: @run, options: @opts, workspace: @workspace, cache: @cache)
          @enabled = resolve_enabled_modules
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
          Nokizaru::Modules::Headers.call(target, ctx) if enabled[:headers]
          Nokizaru::Modules::SSLInfo.call(info[:hostname], info[:ssl_port], ctx) if enabled[:sslinfo]
          Nokizaru::Modules::WhoisLookup.call(info[:domain], info[:suffix], ctx) if enabled[:whois]
          Nokizaru::Modules::DNSEnumeration.call(info[:hostname], info[:dns_servers], ctx) if enabled[:dns]
          run_subdomains(enabled, info, ctx)
          run_architecture(enabled, target, info, ctx)
        end

        def run_optional_modules(enabled, target, info, ctx)
          Nokizaru::Modules::PortScan.call(info[:ip], info[:pscan_threads], ctx) if enabled[:ps]
          Nokizaru::Modules::Crawler.call(target, info[:protocol], info[:netloc], ctx) if enabled[:crawl]
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

          Nokizaru::Modules::Subdomains.call(info[:hostname], info[:timeout], ctx, info[:conf_path])
        end

        def run_architecture(enabled, target, info, ctx)
          return unless enabled[:arch]

          Nokizaru::Modules::ArchitectureFingerprinting.call(target, info[:timeout], ctx, info[:conf_path])
        end

        def run_directory_enum(enabled, target, info, ctx)
          return unless enabled[:dir]

          Nokizaru::Modules::DirectoryEnum.call(
            target,
            info[:dir_threads],
            info[:timeout],
            info[:wordlist],
            info[:allow_redirects],
            info[:verify_ssl],
            info[:extensions],
            ctx
          )
        end

        def run_wayback(enabled, target, info, ctx)
          return unless enabled[:wayback]

          Nokizaru::Modules::Wayback.call(target, ctx, timeout_s: [info[:timeout].to_f, 12.0].min, raw: @opts[:wb_raw])
        end

        def resolve_enabled_modules
          order = %i[headers sslinfo whois dns sub arch ps crawl dir wayback]
          enabled = order.each_with_object({}) { |mod, out| out[mod] = module_enabled?(mod) }
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
