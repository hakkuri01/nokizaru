# frozen_string_literal: true

require 'thor'
require 'json'
require 'uri'
require 'socket'
require 'ipaddr'
require 'fileutils'
require 'public_suffix'
require 'time'

require_relative 'version'
require_relative 'paths'
require_relative 'settings'
require_relative 'log'
require_relative 'modules/headers'
require_relative 'modules/sslinfo'
require_relative 'modules/whois'
require_relative 'modules/dns'
require_relative 'modules/subdom'
require_relative 'modules/arch'
require_relative 'modules/portscan'
require_relative 'modules/crawler'
require_relative 'modules/dirrec'
require_relative 'modules/wayback'
require_relative 'findings/engine'
require_relative 'workspace'
require_relative 'cache_store'
require_relative 'context'
require_relative 'diff'
require_relative 'export_manager'

module Nokizaru
  class CLI < Thor
    R = "\e[31m"
    G = "\e[32m"
    C = "\e[36m"
    W = "\e[0m"

    remove_command :help if respond_to?(:remove_command)

    # Normalize high level CLI flags before handing control to Thor
    def self.start(given_args = ARGV, config = {})
      args = Array(given_args).dup

      if args.length == 1 && ['--version', '-v'].include?(args[0])
        puts "nokizaru #{VERSION}"
        exit(0)
      end

      wants_flag_help = args.include?('--help') || args.include?('-h')
      wants_cmd_help  = (args[0] == 'help')

      if wants_flag_help || wants_cmd_help
        ok = args.length == 1 && ['--help', '-h', 'help'].include?(args[0])

        unless ok
          warn("#{UI.prefix(:error)} #{C}Invalid help syntax#{W}")
          warn("#{UI.prefix(:plus)} #{C}Use #{W}nokizaru --help#{C} (or #{W}-h#{C}) to view the full CLI documentation#{W}")
          exit(1)
        end

        shell_klass = Thor::Base.shell || Thor::Shell::Color
        help(shell_klass.new)
        exit(0)
      end

      super(args, config)
    end

    desc 'help', 'Show Nokizaru help'
    # Print CLI help with strict syntax handling for predictable UX
    def help(*args)
      if args.any?
        UI.line(:error, 'Invalid help syntax')
        UI.line(:plus, 'Use nokizaru --help to view the full CLI documentation')
        exit(1)
      end

      self.class.help(shell)
    end

    # Print unknown command guidance and exit with a nonzero status
    def self.handle_no_command_error(command, _has_namespace = false)
      warn("#{UI.prefix(:error)} #{C}Unknown command : #{W}#{command}#{W}")
      warn("#{UI.prefix(:plus)} #{C}Use #{W}nokizaru --help#{C} to view valid flags and usage#{W}")
      exit(1)
    end

    # Print CLI help with strict syntax handling for predictable UX
    def self.help(shell, _subcommand = false)
      usage = <<~USAGE
        usage: nokizaru [-h] [-v] [--url URL] [--headers] [--sslinfo] [--whois] [--crawl] [--dns] [--sub] [--arch] [--dir] [--wayback] [--wb-raw] [--ps]
                        [--full] [--no-MODULE] [--export] [--project NAME] [--cache] [--no-cache] [--diff last or ID] [-nb] [-dt DT] [-pt PT] [-T T] [-w W] [-r] [-s] [-sp SP] [-d D] [-e E] [-o O] [-cd CD] [-of OF] [-k K]
      USAGE
      shell.say(usage.rstrip)
      shell.say('')
      shell.say("Nokizaru - Recon Refined | v#{VERSION}")
      shell.say('')
      shell.say('Arguments:')
      opt_rows = [
        ['-h, --help', 'Show this help message and exit'],
        ['-v, --version', 'Show version number and exit'],
        ['--url URL', 'Target URL'],
        ['--headers', 'Header Information'],
        ['--sslinfo', 'SSL Certificate Information'],
        ['--whois', 'Whois Lookup'],
        ['--crawl', 'Crawl Target'],
        ['--dns', 'DNS Enumeration'],
        ['--sub', 'Sub-Domain Enumeration'],
        ['--arch', 'Architecture Fingerprinting'],
        ['--dir', 'Directory Search'],
        ['--wayback', 'Wayback URLs'],
        ['--wb-raw', 'Wayback raw URL output (no quality filtering)'],
        ['--ps', 'Fast Port Scan'],
        ['--full', 'Full Recon'],
        ['--no-[MODULE]', 'Skip specified modules above during full scan (eg. --no-dir)'],
        ['--export', 'Write results to export directory [ Default : False ]'],
        ['--project [NAME]', 'Enable a persistent workspace (profiles, caching, diffing)'],
        ['--cache', 'Enable caching even without a project'],
        ['--no-cache', 'Disable caching (even in a project)'],
        ['--diff last / [ID]', 'Diff this run against the last (or another run ID in the workspace)']
      ]
      print_aligned_rows(shell, opt_rows)
      shell.say('')
      shell.say('Extra Options:')
      extra_rows = [
        ['-nb', 'Hide Banner'],
        ['-dt DT', 'Number of threads for directory enum [ Default : 30 ]'],
        ['-pt PT', 'Number of threads for port scan [ Default : 50 ]'],
        ['-T T', 'Request Timeout [ Default : 30.0 ]'],
        ['-w W', 'Path to Wordlist [ Default : wordlists/dirb_common.txt ]'],
        ['-r', 'Allow Redirect [ Default : False ]'],
        ['-s', 'Toggle SSL Verification [ Default : True ]'],
        ['-sp SP', 'Specify SSL Port [ Default : 443 ]'],
        ['-d D', 'Custom DNS Servers [ Default : 1.1.1.1 ]'],
        ['-e E', 'File Extensions [ Example : txt, xml, php, etc. ]'],
        ['-o O', 'Export Formats (comma-separated) [ Default : txt,json,html ]'],
        ['-cd CD',
         'Change export directory (requires --export) [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]'],
        ['-of OF', 'Change export folder name (requires --export) [ Default : YYYY-MM-DD_HH-MM-SS ]'],
        ['-k K', 'Add API key [ Example : shodan@key ]']
      ]
      print_aligned_rows(shell, extra_rows)
      shell.say('')
    end

    # Render aligned option rows so CLI help remains readable
    def self.print_aligned_rows(shell, rows)
      left_width = rows.map { |(l, _)| l.length }.max || 0
      left_width = [left_width, 18].max
      rows.each do |left, right|
        shell.say(format("  %-#{left_width}s %s", left, right))
      end
    end

    default_task :scan

    # Tell Thor to surface failures with nonzero exit codes
    def self.exit_on_failure?
      true
    end

    desc 'scan', "Nokizaru - Recon Refined | v#{VERSION}"

    option :url, type: :string, desc: 'Target URL'
    option :headers, type: :boolean, default: false, desc: 'Header Information'
    option :sslinfo, type: :boolean, default: false, desc: 'SSL Certificate Information'
    option :whois, type: :boolean, default: false, desc: 'Whois Lookup'
    option :crawl, type: :boolean, default: false, desc: 'Crawl Target'
    option :dns, type: :boolean, default: false, desc: 'DNS Enumeration'
    option :sub, type: :boolean, default: false, desc: 'Sub-Domain Enumeration'
    option :arch, type: :boolean, default: false, desc: 'Architecture Fingerprinting'
    option :dir, type: :boolean, default: false, desc: 'Directory Search'
    option :wayback, type: :boolean, default: false, desc: 'Wayback URLs'
    option :wb_raw, type: :boolean, default: false, desc: 'Wayback raw URL output (no quality filtering)'
    option :ps, type: :boolean, default: false, desc: 'Fast Port Scan'
    option :full, type: :boolean, default: false, desc: 'Full Recon'
    option :export, type: :boolean, default: false, desc: 'Export results to files (txt,json,html)'

    option :project, type: :string, default: nil, desc: 'Enable a persistent workspace (profiles, caching, diffing)'
    option :cache, type: :boolean, default: nil, desc: 'Enable caching even without a project'
    option :no_cache, type: :boolean, default: false, desc: 'Disable caching (even in a project)'
    option :diff, type: :string, default: nil, desc: 'Diff this run against another run id in the workspace (or "last")'

    option :nb, type: :boolean, default: false, desc: 'Hide Banner'
    option :dt, type: :numeric, default: nil, desc: 'Number of threads for directory enum [ Default : 30 ]'
    option :pt, type: :numeric, default: nil, desc: 'Number of threads for port scan [ Default : 50 ]'
    option :T,  type: :numeric, default: nil, aliases: '-T', desc: 'Request Timeout [ Default : 30.0 ]'
    option :w,  type: :string,  default: nil, aliases: '-w',
                desc: 'Path to Wordlist [ Default : wordlists/dirb_common.txt ]'
    option :r,  type: :boolean, default: nil, aliases: '-r', desc: 'Allow Redirect [ Default : False ]'
    option :s,  type: :boolean, default: nil, aliases: '-s', desc: 'Toggle SSL Verification [ Default : True ]'
    option :sp, type: :numeric, default: nil, desc: 'Specify SSL Port [ Default : 443 ]'
    option :d,  type: :string,  default: nil, aliases: '-d', desc: 'Custom DNS Servers [ Default : 1.1.1.1 ]'
    option :e,  type: :string,  default: nil, aliases: '-e', desc: 'File Extensions [ Example : txt, xml, php ]'
    option :o,  type: :string,  default: nil, aliases: '-o',
                desc: 'Export Formats (comma-separated) [ Default : txt,json,html ]'
    option :cd, type: :string,  default: nil,
                desc: 'Change export directory [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]'
    option :of, type: :string,  default: nil, desc: 'Change export folder name [ Default : YYYY-MM-DD_HH-MM-SS ]'
    option :k,  type: :string,  default: nil, aliases: '-k', desc: 'Add API key [ Example : shodan@key ]'
    # Validate scan invocation and dispatch execution to the runner
    def scan(*args)
      if args && !args.empty?
        bad = args.join(' ')
        UI.line(:error, "Invalid syntax. Unexpected argument(s) : #{bad}")
        UI.line(:plus, 'If you meant export formats, use -o with comma-separated formats')
        UI.line(:plus, 'Example : nokizaru --headers --url https://example.com --export -o txt,json,html')
        UI.line(:plus, 'Tip : --export is a flag (no positional values)')
        exit(1)
      end

      Runner.new(options, ::ARGV.dup).run
    end

    class Runner
      # Capture constructor arguments and initialize internal state
      def initialize(options, argv = [])
        @opts = options
        @argv = argv || []
        @skip = parse_skip_flags(@argv)
      end

      # Collect skip flags so full scans can disable specific modules
      def parse_skip_flags(argv)
        skip = {}
        %w[headers sslinfo whois crawl dns sub arch dir wayback ps].each do |name|
          skip[name.to_sym] = argv.include?("--skip-#{name}") || argv.include?("--no-#{name}")
        end
        skip
      end

      # Render startup branding and metadata shown during interactive scans
      def banner
        art = <<~'ART'

               ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⣿⣶⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⢤⣤⣀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠸⣿⣿⣀⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⠀⠹⣿⣧⣀⣾⣿⣿⠆⠀⣀⣠⣴⣿⣿⠿⠟⠛⠀⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⠀⠀⣻⣿⣿⠿⠋⠁⠀⠀⠉⠉⢹⣿⣿⠀⠀⠀⣀⣠⣤⣄⠀⠀⠀⠀
               ⠀⠀⠀⢀⣤⠾⠿⣿⡇⠀⢀⠀⣀⣀⣤⣴⡾⠿⠛⠛⠛⠉⠙⠛⠛⠛⠛⠀⠀⠀
               ⠀⠀⠀⠀⠀⠀⠀⣿⡇⠀⠈⢿⠿⠛⣉⠁⢀⣀⣠⣤⣦⣄⠀⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⠀⠀⣼⣿⣿⠀⠀⠀⠀⢺⣿⡟⠋⠉⠁⣼⣿⡿⠁⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⢀⣾⣿⣿⣿⠀⠀⠀⠀⠈⣿⣷⣤⣤⣤⣿⣿⠁⢀⣀⣀⠀⠀⠀⠀⠀
               ⠀⠀⠀⣠⣿⠟⠁⢸⣿⠀⠀⠀⠀⠀⠹⣿⣿⣯⡉⠉⠀⣠⣾⣿⠟⠀⠀⠀⠀⠀
               ⠀⣠⣾⠟⠁⠀⠀⢸⣿⠀⠀⠀⠀⠀⣠⣿⣿⡁⠙⢷⣾⡟⠉⠀⠀⠀⠀⠀⠀⠀
               ⠈⠉⠀⠀⠀⠀⠀⢸⣿⠀⠀⠀⢀⣼⡿⠋⣿⡇⠀⠀⠙⣿⣦⣄⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⠀⠀⠀⣾⣿⠀⣠⣴⠟⠋⠀⢀⣿⡇⠀⠀⠀⡈⠻⣿⣷⣦⣄⠀⠀⠀
               ⠀⠀⠀⠱⣶⣤⣴⣿⣿⠀⠁⠀⠀⠀⠀⢸⣿⡇⣀⣴⡾⠁⠀⠈⠻⠿⠿⠿⠷⠖
               ⠀⠀⠀⠀⠈⠻⣿⣿⡇⠀⠀⠀⠀⠀⢀⣾⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
               ⠀⠀⠀⠀⠀⠀⠈⠉⠀⠀⠀⠀⠀⠀⠀⢻⡿⠟⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
           ▐ ▄       ▄ •▄ ▪  ·▄▄▄▄• ▄▄▄· ▄▄▄  ▄• ▄▌
          •█▌▐█▪     █▌▄▌▪██ ▪▀·.█▌▐█ ▀█ ▀▄ █·█▪██▌
          ▐█▐▐▌ ▄█▀▄ ▐▀▀▄·▐█·▄█▀▀▀•▄█▀▀█ ▐▀▀▄ █▌▐█▌
          ██▐█▌▐█▌.▐▌▐█.█▌▐█▌█▌▪▄█▀▐█ ▪▐▌▐█•█▌▐█▄█▌
          ▀▀ █▪ ▀█▄▀▪·▀  ▀▀▀▀·▀▀▀ • ▀  ▀ .▀  ▀ ▀▀▀
        ART

        puts("#{CLI::G}#{art}#{CLI::W}\n")
        puts("#{CLI::G}⟦+⟧#{CLI::C} Created By   :#{CLI::W} hakkuri")
        puts("#{CLI::G} ├─◈#{CLI::C} ⟦GIT⟧       :#{CLI::W} https://github.com/hakkuri01")
        puts("#{CLI::G} └─◈#{CLI::C} ⟦LOG⟧       :#{CLI::W} Issues/PRs welcome")
        puts("#{CLI::G}⟦+⟧#{CLI::C} Version      :#{CLI::W} #{Nokizaru::VERSION}")
      end

      # Validate key syntax and persist supported provider keys safely
      def save_key(key_string)
        valid_keys = %w[bevigil binedge facebook netlas shodan virustotal zoomeye hunter chaos censys_api_id
                        censys_api_secret wappalyzer]

        key_string = key_string.to_s.strip
        key_name, key_str = key_string.split('@', 2)

        if key_name.to_s.strip.empty? || key_str.to_s.strip.empty?
          UI.line(:error, 'Invalid key syntax')
          UI.line(:plus, 'Use : -k name@key (example: shodan@ABC123)')
          Log.write('Invalid key syntax supplied')
          exit(1)
        end

        unless valid_keys.include?(key_name)
          UI.line(:error, 'Invalid key name!')
          UI.row(:plus, 'Valid key names', valid_keys.join(', '))
          Log.write('Invalid key name, exiting')
          exit(1)
        end

        Paths.sync_default_conf!

        keys_json = {}
        begin
          keys_json = JSON.parse(File.read(Paths.keys_file))
        rescue StandardError
          keys_json = {}
        end

        keys_json[key_name] = key_str
        File.write(Paths.keys_file, JSON.pretty_generate(keys_json))

        UI.line(:info, "#{key_name} key saved (not validated)")
        exit(0)
      end

      # Execute the full scan lifecycle from setup through reporting and export
      def run
        Log.write('Importing config...')
        Settings.load!

        Log.write(
          "PATHS = HOME:#{Paths.home}, SCRIPT_LOC:#{Paths.project_root}, " \
          "METADATA:#{Paths.metadata_file}, KEYS:#{Paths.keys_file}, " \
          "CONFIG:#{Paths.config_file}, LOG:#{Paths.log_file}"
        )

        Log.write("Nokizaru v#{Nokizaru::VERSION}")

        banner unless @opts[:nb]
        save_key(@opts[:k]) if @opts[:k]

        ensure_modules_selected!

        target = @opts[:url].to_s
        if target.empty?
          UI.line(:error, 'No Target Specified!')
          exit(1)
        end

        unless target.start_with?('http://', 'https://')
          UI.line(:error, 'Protocol Missing, Include http:// or https://')
          Log.write("Protocol missing in #{target}, exiting")
          exit(1)
        end

        target = target.chomp('/')
        UI.row(:info, 'Target', target)

        info = parse_target(target)

        workspace = nil
        if @opts[:project] && !@opts[:project].to_s.strip.empty?
          workspace = Nokizaru::Workspace.new(@opts[:project], info[:hostname])
        end

        cache = nil
        caching_enabled = !@opts[:no_cache] && (workspace || @opts[:cache])
        cache = Nokizaru::CacheStore.new(workspace ? workspace.cache_dir : Paths.cache_dir) if caching_enabled

        start_time = Time.now

        run = {
          'meta' => {
            'version' => Nokizaru::VERSION,
            'target' => target,
            'hostname' => info[:hostname],
            'ip' => info[:ip],
            'started_at' => start_time.utc.iso8601
          },
          'modules' => {},
          'artifacts' => {},
          'findings' => []
        }

        run_id = nil
        if workspace
          run_id, _run_dir = workspace.start_run(run['meta'])
          run['meta']['workspace'] = {
            'project' => workspace.project_name,
            'target' => workspace.target_host,
            'run_id' => run_id,
            'base_dir' => workspace.base_dir
          }
          UI.row(:info, 'Workspace enabled', workspace.base_dir)
        end

        ctx = Nokizaru::Context.new(run: run, options: @opts, workspace: workspace, cache: cache)

        order = %i[headers sslinfo whois dns sub arch ps crawl dir wayback]

        enabled = {}
        if @opts[:full]
          Log.write('Starting full recon...')
          order.each { |m| enabled[m] = true }
        else
          order.each { |m| enabled[m] = !!@opts[m] }
        end

        @skip.each { |k, v| enabled[k] = false if v }

        unless enabled.values.any?
          UI.line(:error, 'No Modules Specified! Use --full or a module flag')
          exit(1)
        end

        Nokizaru::Modules::Headers.call(target, ctx) if enabled[:headers]
        Nokizaru::Modules::SSLInfo.call(info[:hostname], info[:ssl_port], ctx) if enabled[:sslinfo]
        Nokizaru::Modules::WhoisLookup.call(info[:domain], info[:suffix], ctx) if enabled[:whois]
        Nokizaru::Modules::DNSEnumeration.call(info[:hostname], info[:dns_servers], ctx) if enabled[:dns]

        if enabled[:sub]
          if info[:type_ip]
            UI.line(:error, 'Skipping Sub-Domain Enumeration : Not Supported for IP Addresses')
            exit(1) unless @opts[:full]
          elsif !info[:private_ip]
            Nokizaru::Modules::Subdomains.call(info[:hostname], info[:timeout], ctx, info[:conf_path])
          end
        end

        if enabled[:arch]
          Nokizaru::Modules::ArchitectureFingerprinting.call(target, info[:timeout], ctx,
                                                             info[:conf_path])
        end

        Nokizaru::Modules::PortScan.call(info[:ip], info[:pscan_threads], ctx) if enabled[:ps]
        Nokizaru::Modules::Crawler.call(target, info[:protocol], info[:netloc], ctx) if enabled[:crawl]

        if enabled[:dir]
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

        if enabled[:wayback]
          Nokizaru::Modules::Wayback.call(
            target,
            ctx,
            timeout_s: [info[:timeout].to_f, 12.0].min,
            raw: @opts[:wb_raw]
          )
        end

        elapsed = Time.now - start_time
        run['meta']['ended_at'] = Time.now.utc.iso8601
        run['meta']['elapsed_s'] = elapsed

        begin
          run['findings'] = Nokizaru::Findings::Engine.new.run(run)
          print_findings(run['findings'])
        rescue StandardError => e
          Log.write("[findings] Exception = #{e.class}: #{e}")
          run['findings'] = []
        end

        if workspace
          db_ingest_ok = workspace.ingest_run!(run)
          run['db_snapshot'] = workspace.db_snapshot

          db_status = build_workspace_db_status(
            workspace: workspace,
            ingest_ok: db_ingest_ok,
            snapshot: run['db_snapshot']
          )
          run['meta']['workspace']['db'] = db_status
          print_workspace_db_status(db_status)
        end

        diff_target = resolve_diff_target
        if diff_target && !workspace
          UI.line(:error, 'Diff requested without an active workspace')
          UI.line(:plus, 'Enable a workspace with: --project <name>')
          UI.row(:plus, 'Workspace base', Paths.workspace_dir)
          Log.write('Diff requested without workspace; skipping')
        end

        if workspace && diff_target
          diff_ref = resolve_diff_reference(workspace, run_id, diff_target)
          if diff_ref[:ok]
            prev_id = diff_ref[:run_id]
            old_run = workspace.load_run(prev_id)
            run['diff'] = Nokizaru::Diff.compute(old_run, run)

            run['diff_db'] = if old_run['db_snapshot'].is_a?(Hash) && run['db_snapshot'].is_a?(Hash)
                               Nokizaru::Workspace.diff_snapshots(old_run['db_snapshot'], run['db_snapshot'])
                             else
                               {}
                             end

            UI.row(:info, 'Diffed against run', prev_id)
            print_db_diff(run['diff_db'], label: 'Ronin DB diff')
          else
            UI.line(:error, diff_ref[:message].to_s)
          end
        end

        workspace.save_run(run_id, run) if workspace && run_id

        export_dir = nil
        if @opts[:export]
          formats = export_formats
          custom_dir = resolve_custom_export_directory(workspace, run_id)
          custom_basename = @opts[:of].to_s.strip.empty? ? nil : @opts[:of].to_s.strip

          begin
            export_paths = Nokizaru::ExportManager.new.export(
              run,
              domain: info[:hostname],
              formats: formats,
              custom_directory: custom_dir,
              custom_basename: custom_basename
            )
            export_dir = File.dirname(export_paths.values.first) if export_paths.any?
          rescue ArgumentError => e
            UI.line(:error, "Export failed : #{e.message}")
            UI.line(:plus, 'Supported formats : txt,json,html')
            Log.write("[export] #{e.class}: #{e.message}")
            exit(1)
          end
        end

        UI.row(:info, 'Completed in', format('%.2f', elapsed) + 's')
        UI.row(:info, 'Workspace run saved', workspace.run_dir(run_id)) if workspace && run_id
        UI.row(:info, 'Exported', export_dir) if export_dir
        Log.write('-' * 30)
      end

      private

      # Print findings in a concise severity aware terminal view
      def print_findings(findings)
        findings = Array(findings)
        return if findings.empty?

        UI.module_header('Findings')
        findings.each do |f|
          sev = (f['severity'] || 'low').to_s.upcase
          title = f['title'] || 'Finding'
          mod = f['module'] ? " (#{f['module']})" : ''
          UI.line(:info, "#{colorize_finding_severity(sev)} #{title}#{mod}")
          UI.tree_rows([['Evidence', f['evidence']]]) if f['evidence']
        end
      end

      def colorize_finding_severity(severity)
        label = severity.to_s.upcase
        color = case label
                when 'CRITICAL', 'HIGH'
                  UI::R
                when 'MEDIUM'
                  UI::Y
                else
                  UI::G
                end
        "#{UI::W}⟦ #{color}#{label}#{UI::W} ⟧"
      end

      # Print run to run database deltas grouped by artifact type
      def print_db_diff(diff_db, label:)
        diff_db = diff_db.is_a?(Hash) ? diff_db : {}
        return if diff_db.empty?

        UI.line(:info, "#{label}:")
        diff_db.each do |kind, change|
          added = Array(change['added']).length
          removed = Array(change['removed']).length
          UI.row(:info, kind.to_s, "+#{added} / -#{removed}")
        end
      end

      # Build workspace database health metadata for the run payload
      def build_workspace_db_status(workspace:, ingest_ok:, snapshot:)
        available = workspace.db_available?
        error = workspace.last_db_error.to_s.strip
        collections = snapshot.is_a?(Hash) ? snapshot.keys.length : 0

        state = if !available
                  'unavailable'
                elsif error.empty? && ingest_ok
                  'enabled'
                else
                  'degraded'
                end

        {
          'state' => state,
          'available' => available,
          'ingest_ok' => !!ingest_ok,
          'snapshot_collections' => collections,
          'error' => error
        }
      end

      # Print workspace database status with actionable diagnostics
      def print_workspace_db_status(db_status)
        state = db_status['state'].to_s
        error = db_status['error'].to_s
        collections = db_status['snapshot_collections']

        case state
        when 'enabled'
          UI.row(:info, 'Workspace DB', "enabled (collections: #{collections})")
        when 'unavailable'
          msg = error.empty? ? 'ronin-db not installed' : error
          UI.row(:error, 'Workspace DB', "unavailable (#{msg})")
        else
          msg = error.empty? ? 'partial ingest/snapshot failure' : error
          UI.row(:error, 'Workspace DB', "degraded (#{msg})")
        end
      end

      # Resolve diff target and fail clearly when prior run data is missing
      def resolve_diff_reference(workspace, run_id, diff_target)
        all_run_ids = workspace.run_ids

        if diff_target == 'last'
          prev_id = workspace.previous_run_id(run_id)
          return { ok: false, message: 'No prior run found in this workspace.' } unless prev_id

          unless File.exist?(workspace.results_path(prev_id))
            return { ok: false, message: "Run #{prev_id} is missing results.json; cannot diff." }
          end

          return { ok: true, run_id: prev_id }
        end

        requested_id = diff_target.to_s
        unless all_run_ids.include?(requested_id)
          return { ok: false, message: "Diff run ID not found: #{requested_id}" }
        end

        unless File.exist?(workspace.results_path(requested_id))
          return { ok: false, message: "Run #{requested_id} is missing results.json; cannot diff." }
        end

        { ok: true, run_id: requested_id }
      end

      # Fail fast when no scan modules are selected
      def ensure_modules_selected!
        module_flags = %i[full headers sslinfo whois crawl dns sub arch wayback ps dir]
        return if module_flags.any? { |k| @opts[k] }

        UI.line(:error, 'At least one argument is required. Try using --help')
        exit(1)
      end

      # Normalize export format flags and apply default formats
      def export_formats
        raw = @opts[:o].to_s.strip
        return %w[txt json html] if raw.empty?

        raw.split(',').map(&:strip).reject(&:empty?).map(&:downcase).uniq
      end

      # Resolve requested diff target and map blank diff to last run
      def resolve_diff_target
        return 'last' if @argv.include?('--diff') && (@opts[:diff].nil? || @opts[:diff].to_s.strip.empty?)

        v = @opts[:diff]
        return nil if v.nil?

        s = v.to_s.strip
        s.empty? ? nil : s
      end

      # Resolves a custom export directory if specified via CLI options
      # Returns nil if default behavior should be used
      def resolve_custom_export_directory(workspace, run_id)
        return @opts[:cd] if @opts[:cd] && !@opts[:cd].to_s.strip.empty?
        return workspace.run_dir(run_id) if workspace && run_id

        nil
      end

      # Parse target URL and derive module settings from options and defaults
      def parse_target(target)
        uri = URI.parse(target)
        hostname = uri.host.to_s
        if hostname.empty?
          UI.line(:error, 'Unable to parse hostname from target')
          exit(1)
        end

        protocol = uri.scheme.to_s
        port = uri.port
        default_port = (protocol == 'https' ? 443 : 80)
        netloc = port && port != default_port ? "#{hostname}:#{port}" : hostname

        type_ip = ip_literal?(hostname)
        ip = nil
        private_ip = false

        if type_ip
          ip = hostname
          private_ip = IPAddr.new(ip).private?
        else
          addrinfos = Addrinfo.getaddrinfo(hostname, nil, :UNSPEC, :STREAM)
          ai = addrinfos.find { |a| a.ip? && a.ipv4? } || addrinfos.find { |a| a.ip? }
          raise 'no A/AAAA records' unless ai

          ip = ai.ip_address
          UI.row(:info, 'IP Address', ip)
          private_ip = IPAddr.new(ip).private?
        end

        domain, suffix = extract_domain_parts(hostname)

        {
          protocol: protocol,
          hostname: hostname,
          netloc: netloc,
          domain: domain,
          suffix: suffix,
          ip: ip,
          type_ip: type_ip,
          private_ip: private_ip,
          conf_path: Paths.config_dir + '/',
          timeout: (@opts[:T] || Settings.timeout).to_f,
          dns_servers: (@opts[:d] || Settings.custom_dns).to_s,
          ssl_port: Integer(@opts[:sp] || Settings.ssl_port),
          pscan_threads: Integer(@opts[:pt] || Settings.port_scan_threads),
          dir_threads: Integer(@opts[:dt] || Settings.dir_enum_threads),
          wordlist: (@opts[:w] || Settings.dir_enum_wordlist).to_s,
          allow_redirects: @opts[:r].nil? ? Settings.dir_enum_redirect : !!@opts[:r],
          verify_ssl: @opts[:s].nil? ? Settings.dir_enum_verify_ssl : !!@opts[:s],
          extensions: (@opts[:e] || Settings.dir_enum_extension).to_s
        }
      end

      # Detect whether the hostname is an IP literal
      def ip_literal?(hostname)
        IPAddr.new(hostname)
        true
      rescue StandardError
        false
      end

      # Extract registrable domain parts used by domain based modules
      def extract_domain_parts(hostname)
        return ['', ''] if ip_literal?(hostname)

        parsed = PublicSuffix.parse(hostname)
        [parsed.sld.to_s, parsed.tld.to_s]
      rescue StandardError
        [hostname.to_s, '']
      end
    end
  end
end
