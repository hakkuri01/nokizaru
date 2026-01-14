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

    def self.start(given_args = ARGV, config = {})
      args = Array(given_args).dup

      wants_flag_help = args.include?('--help') || args.include?('-h')
      wants_cmd_help  = (args[0] == 'help')

      if wants_flag_help || wants_cmd_help
        ok = args.length == 1 && ['--help', '-h', 'help'].include?(args[0])

        unless ok
          warn("#{R}[-] #{C}Invalid help syntax.#{W}")
          warn("#{G}[+] #{C}Use #{W}nokizaru --help#{C} (or #{W}-h#{C}) to view the full CLI documentation.#{W}")
          exit(1)
        end

        shell_klass = Thor::Base.shell || Thor::Shell::Color
        help(shell_klass.new)
        exit(0)
      end

      super(args, config)
    end

    desc 'help', 'Show Nokizaru help'
    def help(*args)
      if args.any?
        puts("#{R}[-] #{C}Invalid help syntax.#{W}")
        puts("#{G}[+] #{C}Use #{W}nokizaru --help#{C} to view the full CLI documentation.#{W}")
        exit(1)
      end

      self.class.help(shell)
    end

    def self.handle_no_command_error(command, _has_namespace = false)
      warn("#{R}[-] #{C}Unknown command: #{W}#{command}#{W}")
      warn("#{G}[+] #{C}Use #{W}nokizaru --help#{C} to view valid flags and usage.#{W}")
      exit(1)
    end

    def self.help(shell, _subcommand = false)
      usage = <<~USAGE
        usage: nokizaru [--url URL] [--headers] [--sslinfo] [--whois] [--crawl] [--dns] [--sub] [--dir] [--wayback] [--ps]
                        [--full] [--no-MODULE] [--export] [--project NAME] [--cache] [--no-cache] [--diff last or ID] [-nb] [-dt DT] [-pt PT] [-T T] [-w W] [-r] [-s] [-sp SP] [-d D] [-e E] [-o O] [-cd CD] [-of OF] [-k K]
      USAGE
      shell.say(usage.rstrip)
      shell.say('')
      shell.say("Nokizaru - Recon Refined | v#{VERSION}")
      shell.say('')
      shell.say('Arguments:')
      opt_rows = [
        ['-h, --help', 'Show this help message and exit'],
        ['--url URL', 'Target URL'],
        ['--headers', 'Header Information'],
        ['--sslinfo', 'SSL Certificate Information'],
        ['--whois', 'Whois Lookup'],
        ['--crawl', 'Crawl Target'],
        ['--dns', 'DNS Enumeration'],
        ['--sub', 'Sub-Domain Enumeration'],
        ['--dir', 'Directory Search'],
        ['--wayback', 'Wayback URLs'],
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

    def self.print_aligned_rows(shell, rows)
      left_width = rows.map { |(l, _)| l.length }.max || 0
      left_width = [left_width, 18].max
      rows.each do |left, right|
        shell.say(format("  %-#{left_width}s %s", left, right))
      end
    end

    default_task :scan

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
    option :dir, type: :boolean, default: false, desc: 'Directory Search'
    option :wayback, type: :boolean, default: false, desc: 'Wayback URLs'
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
    def scan(*args)
      if args && !args.empty?
        bad = args.join(' ')
        puts("#{R}[-] #{C}Invalid syntax. Unexpected argument(s): #{W}#{bad}#{W}")
        puts("#{G}[+] #{C}If you meant export formats, use #{W}-o#{C} with comma-separated formats.#{W}")
        puts("#{G}[+] #{C}Example: #{W}nokizaru --headers --url https://example.com --export -o txt,json,html#{W}")
        puts("#{G}[+] #{C}Tip: #{W}--export#{C} is a flag (no positional values).#{W}")
        exit(1)
      end

      Runner.new(options, ::ARGV.dup).run
    end

    class Runner
      def initialize(options, argv = [])
        @opts = options
        @argv = argv || []
        @skip = parse_skip_flags(@argv)
      end

      def parse_skip_flags(argv)
        skip = {}
        %w[headers sslinfo whois crawl dns sub dir wayback ps].each do |name|
          skip[name.to_sym] = argv.include?("--skip-#{name}") || argv.include?("--no-#{name}")
        end
        skip
      end

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

      def save_key(key_string)
        valid_keys = %w[bevigil binedge facebook netlas shodan virustotal zoomeye hunter]

        key_string = key_string.to_s.strip
        key_name, key_str = key_string.split('@', 2)

        if key_name.to_s.strip.empty? || key_str.to_s.strip.empty?
          puts("#{CLI::R}[-] #{CLI::C}Invalid key syntax.#{CLI::W}")
          puts("#{CLI::G}[+] #{CLI::C}Use: #{CLI::W}-k name@key#{CLI::W} (example: #{CLI::W}shodan@ABC123#{CLI::W})")
          Log.write('Invalid key syntax supplied')
          exit(1)
        end

        unless valid_keys.include?(key_name)
          puts("#{CLI::R}[-] #{CLI::C}Invalid key name!#{CLI::W}")
          puts("#{CLI::G}[+] #{CLI::C}Valid key names: #{CLI::W}#{valid_keys.join(', ')}#{CLI::W}")
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

        puts("#{CLI::G}[+] #{CLI::W}#{key_name} #{CLI::C}key saved.#{CLI::W} (not validated)")
        exit(0)
      end

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
          puts("#{CLI::R}[-] #{CLI::C}No Target Specified!#{CLI::W}")
          exit(1)
        end

        unless target.start_with?('http://', 'https://')
          puts("#{CLI::R}[-] #{CLI::C}Protocol Missing, Include #{CLI::W}http:// #{CLI::C}or#{CLI::W} https:// \n")
          Log.write("Protocol missing in #{target}, exiting")
          exit(1)
        end

        target = target.chomp('/')
        puts("#{CLI::G}[+] #{CLI::C}Target : #{CLI::W}#{target}")

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
          puts("#{CLI::G}[+] #{CLI::C}Workspace enabled : #{CLI::W}#{workspace.base_dir}")
        end

        ctx = Nokizaru::Context.new(run: run, options: @opts, workspace: workspace, cache: cache)

        order = %i[headers sslinfo whois dns sub ps crawl dir wayback]

        enabled = {}
        if @opts[:full]
          Log.write('Starting full recon...')
          order.each { |m| enabled[m] = true }
        else
          order.each { |m| enabled[m] = !!@opts[m] }
        end

        @skip.each { |k, v| enabled[k] = false if v }

        unless enabled.values.any?
          puts("#{CLI::R}[-] #{CLI::C}No Modules Specified! Use#{CLI::W} --full #{CLI::C}or a module flag.#{CLI::W}")
          exit(1)
        end

        Nokizaru::Modules::Headers.call(target, ctx) if enabled[:headers]
        Nokizaru::Modules::SSLInfo.call(info[:hostname], info[:ssl_port], ctx) if enabled[:sslinfo]
        Nokizaru::Modules::WhoisLookup.call(info[:domain], info[:suffix], ctx) if enabled[:whois]
        Nokizaru::Modules::DNSEnumeration.call(info[:hostname], info[:dns_servers], ctx) if enabled[:dns]

        if enabled[:sub]
          if info[:type_ip]
            puts("#{CLI::R}[-] #{CLI::C}Sub-Domain Enumeration is Not Supported for IP Addresses#{CLI::W}\n")
            exit(1)
          elsif !info[:private_ip]
            Nokizaru::Modules::Subdomains.call(info[:hostname], info[:timeout], ctx, info[:conf_path])
          end
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

        Nokizaru::Modules::Wayback.call(target, ctx, timeout_s: [info[:timeout].to_f, 10.0].min) if enabled[:wayback]

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
          workspace.ingest_run!(run)
          run['db_snapshot'] = workspace.db_snapshot
        end

        workspace.save_run(run_id, run) if workspace && run_id

        diff_target = resolve_diff_target
        if diff_target && !workspace
          puts("\n#{CLI::R}[-] #{CLI::C}Diff requested but no workspace is enabled.#{CLI::W}")
          puts("#{CLI::G}[+] #{CLI::C}Re-run with: #{CLI::W}--project <name>#{CLI::W}")
          puts("#{CLI::G}[+] #{CLI::C}Workspace base: #{CLI::W}#{Paths.workspace_dir}#{CLI::W}")
          Log.write('Diff requested without workspace; skipping')
        end

        if workspace && diff_target
          prev_id = diff_target == 'last' ? workspace.previous_run_id(run_id) : diff_target
          if prev_id && File.exist?(workspace.results_path(prev_id))
            old_run = workspace.load_run(prev_id)
            run['diff'] = Nokizaru::Diff.compute(old_run, run)

            run['diff_db'] = if old_run['db_snapshot'].is_a?(Hash) && run['db_snapshot'].is_a?(Hash)
                               Nokizaru::Workspace.diff_snapshots(old_run['db_snapshot'], run['db_snapshot'])
                             else
                               {}
                             end

            puts("\n#{CLI::G}[+] #{CLI::C}Diffed against run #{CLI::W}#{prev_id}")
            print_db_diff(run['diff_db'], label: 'Ronin DB diff')
          else
            puts("\n#{CLI::R}[-] #{CLI::C}No previous run to diff against.#{CLI::W}")
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
            puts("\n#{CLI::R}[-] #{CLI::C}Export failed: #{CLI::W}#{e.message}")
            puts("#{CLI::G}[+] #{CLI::C}Supported formats: #{CLI::W}txt,json,html#{CLI::W}")
            Log.write("[export] #{e.class}: #{e.message}")
            exit(1)
          end
        end

        puts("\n#{CLI::G}[+] #{CLI::C}Completed in #{CLI::W}#{format('%.2f', elapsed)}s")
        puts("#{CLI::G}[+] #{CLI::C}Workspace run saved : #{CLI::W}#{workspace.run_dir(run_id)}") if workspace && run_id
        puts("#{CLI::G}[+] #{CLI::C}Exported : #{CLI::W}#{export_dir}") if export_dir
        Log.write('-' * 30)
      end

      private

      def print_findings(findings)
        findings = Array(findings)
        return if findings.empty?

        puts("\n#{CLI::G}[+] #{CLI::C}Findings#{CLI::W}")
        findings.each do |f|
          sev = (f['severity'] || 'low').to_s.upcase
          title = f['title'] || 'Finding'
          mod = f['module'] ? " (#{f['module']})" : ''
          puts("  #{CLI::G}[#{sev}]#{CLI::W} #{title}#{mod}")
          puts("       #{CLI::C}Evidence:#{CLI::W} #{f['evidence']}") if f['evidence']
        end
      end

      def print_db_diff(diff_db, label:)
        diff_db = diff_db.is_a?(Hash) ? diff_db : {}
        return if diff_db.empty?

        puts("#{CLI::G}[+] #{CLI::C}#{label}:#{CLI::W}")
        diff_db.each do |kind, change|
          added = Array(change['added']).length
          removed = Array(change['removed']).length
          puts("  #{CLI::C}#{kind}#{CLI::W}  +#{added} / -#{removed}")
        end
      end

      def ensure_modules_selected!
        module_flags = %i[full headers sslinfo whois crawl dns sub wayback ps dir]
        return if module_flags.any? { |k| @opts[k] }

        puts("\n#{CLI::R}[-] Error : #{CLI::C}At least one argument is required. Try using --help#{CLI::W}")
        exit(1)
      end

      def export_formats
        raw = @opts[:o].to_s.strip
        return %w[txt json html] if raw.empty?

        raw.split(',').map(&:strip).reject(&:empty?).map(&:downcase).uniq
      end

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

      def parse_target(target)
        uri = URI.parse(target)
        hostname = uri.host.to_s
        if hostname.empty?
          puts("#{CLI::R}[-] #{CLI::C}Unable to parse hostname from target#{CLI::W}")
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
          puts("\n#{CLI::G}[+] #{CLI::C}IP Address : #{CLI::W}#{ip}")
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

      def ip_literal?(hostname)
        IPAddr.new(hostname)
        true
      rescue StandardError
        false
      end

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
