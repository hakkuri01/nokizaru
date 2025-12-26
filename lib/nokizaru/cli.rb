# frozen_string_literal: true

require 'thor'
require 'json'
require 'uri'
require 'socket'
require 'ipaddr'
require 'fileutils'
require 'public_suffix'
require_relative 'version'
require_relative 'paths'
require_relative 'settings'
require_relative 'log'
require_relative 'modules/export'
require_relative 'modules/headers'
require_relative 'modules/sslinfo'
require_relative 'modules/whois'
require_relative 'modules/dns'
require_relative 'modules/subdom'
require_relative 'modules/portscan'
require_relative 'modules/crawler'
require_relative 'modules/dirrec'
require_relative 'modules/wayback'

module Nokizaru
  class CLI < Thor
    R = "\e[31m"
    G = "\e[32m"
    C = "\e[36m"
    W = "\e[0m"

    # Remove Thor's built-in `help` command and replace it with curated help
    remove_command :help if respond_to?(:remove_command)

    # Intercept -h/--help anywhere and always show curated help
    def self.start(given_args = ARGV, config = {})
      args = Array(given_args).dup

      wants_flag_help = args.include?('--help') || args.include?('-h')
      wants_cmd_help  = (args[0] == 'help')

      if wants_flag_help || wants_cmd_help
        ok =
          (args.length == 1 && (args[0] == '--help' || args[0] == '-h' || args[0] == 'help'))

        unless ok
          $stderr.puts("#{R}[-] #{C}Invalid help syntax.#{W}")
          $stderr.puts("#{G}[+] #{C}Use #{W}nokizaru --help#{C} (or #{W}-h#{C}) to view the full CLI documentation.#{W}")
          exit(1)
        end

        shell_klass = Thor::Base.shell || Thor::Shell::Color
        help(shell_klass.new)
        exit(0)
      end

      super(args, config)
    end

    # `help` command only valid as `nokizaru help`
    desc 'help', 'Show Nokizaru help'
    def help(*args)
      if args.any?
        puts("#{R}[-] #{C}Invalid help syntax.#{W}")
        puts("#{G}[+] #{C}Use #{W}nokizaru --help#{C} to view the full CLI documentation.#{W}")
        exit(1)
      end

      self.class.help(shell)
    end

    # Make unknown commands error without using Thor's default output.
    def self.handle_no_command_error(command, _has_namespace = false)
      $stderr.puts("#{R}[-] #{C}Unknown command: #{W}#{command}#{W}")
      $stderr.puts("#{G}[+] #{C}Use #{W}nokizaru --help#{C} to view valid flags and usage.#{W}")
      exit(1)
    end

    def self.help(shell, subcommand = false)
      usage = <<~USAGE
        usage: nokizaru [--url URL] [--headers] [--sslinfo] [--whois] [--crawl] [--dns] [--sub] [--dir] [--wayback] [--ps]
                        [--full] [--no-<MODULE>] [--export] [-nb] [-dt DT] [-pt PT] [-T T] [-w W] [-r] [-s] [-sp SP] [-d D] [-e E] [-o O] [-cd CD] [-of OF] [-k K]
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
        ['--no-MODULE', 'Skip specified modules above during full scan (eg. --no-dir)'],
        ['--export', 'Write results to export directory [ Default : False ]']
      ]
      print_aligned_rows(shell, opt_rows)
      shell.say('')
      shell.say('Extra Options:')
      extra_rows = [
        ['-nb', 'Hide Banner'],
        ['-dt DT', 'Number of threads for directory enum [ Default : 50 ]'],
        ['-pt PT', 'Number of threads for port scan [ Default : 50 ]'],
        ['-T T', 'Request Timeout [ Default : 30.0 ]'],
        ['-w W', 'Path to Wordlist [ Default : wordlists/dirb_common.txt ]'],
        ['-r', 'Allow Redirect [ Default : False ]'],
        ['-s', 'Toggle SSL Verification [ Default : True ]'],
        ['-sp SP', 'Specify SSL Port [ Default : 443 ]'],
        ['-d D', 'Custom DNS Servers [ Default : 1.1.1.1 ]'],
        ['-e E', 'File Extensions [ Example : txt, xml, php, etc. ]'],
        ['-o O', 'Export Format (requires --export) [ Default : txt ]'],
        ['-cd CD', 'Change export directory (requires --export) [ Default : ~/.local/share/nokizaru ]'],
        ['-of OF', 'Change export folder name (requires --export) [ Default : nk_<host>_<DD-MM-YYYY>_<HH:MM:SS> ]'],
        ['-k K', 'Add API key [ Example : shodan@key ]']
      ]
      print_aligned_rows(shell, extra_rows)
      shell.say('')
    end

    def self.print_aligned_rows(shell, rows)
      # A lightweight table renderer without pulling in additional deps.
      left_width = rows.map { |(l, _)| l.length }.max || 0
      left_width = [left_width, 18].max
      rows.each do |left, right|
        shell.say(format("  %-#{left_width}s %s", left, right))
      end
    end

    default_task :scan

    # Thor 1.4+ deprecates exiting with status 0 on errors.
    # Returning true ensures non-zero exit codes on failures.
    def self.exit_on_failure?
      true
    end

    desc 'scan', "Nokizaru - Recon Refined | v#{VERSION}"

    # Arguments
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
    option :export, type: :boolean, default: false, desc: 'Export results to files'

    # Extra options
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
    option :o,  type: :string,  default: nil, aliases: '-o', desc: 'Export Format [ Default : txt ]'
    option :cd, type: :string,  default: nil, desc: 'Change export directory [ Default : ~/.local/share/nokizaru ]'
    option :of, type: :string,  default: nil, desc: 'Change export folder name [ Default :<path>nk_<hostname>_<date> ]'
    option :k,  type: :string,  default: nil, aliases: '-k', desc: 'Add API key [ Example : shodan@key ]'
    def scan
      # Keep a copy of argv so we can respect --skip-* overrides when --full is used.
      Runner.new(options, ::ARGV.dup).run
    end

    class Runner
      def initialize(options, argv = [])
        @opts = options
        @argv = argv || []
        @skip = parse_skip_flags(@argv)
      end

      # When running --full, users expect --skip-<module> (or --no-<module>) to override.
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
        key_name, key_str = key_string.split('@', 2)

        unless valid_keys.include?(key_name)
          puts("#{CLI::R}[-] #{CLI::C}Invalid key name!#{CLI::W}")
          Log.write('Invalid key name, exiting')
          exit(1)
        end

        keys_json = JSON.parse(File.read(Paths.keys_file))
        keys_json[key_name] = key_str
        File.write(Paths.keys_file, JSON.pretty_generate(keys_json))

        puts("#{CLI::G}[+] #{CLI::W}#{key_name} #{CLI::C}Key Added!#{CLI::W}")
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

        show_banner = !@opts[:nb]
        banner if show_banner

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

        output = nil
        respath = nil
        if @opts[:export]
          output, respath = build_output_settings(info[:hostname])
        end

        data = {}

        start_time = Time.now

        # Determine which modules to run once.
        order = [:headers, :sslinfo, :whois, :dns, :sub, :ps, :crawl, :dir, :wayback]

        enabled = {}
        if @opts[:full]
          Log.write('Starting full recon...')
          order.each { |m| enabled[m] = true }
        else
          order.each { |m| enabled[m] = !!@opts[m] }
        end

        # Respect explicit skip flags even when --full is set.
        @skip.each { |k, v| enabled[k] = false if v }

        unless enabled.values.any?
          puts("#{CLI::R}[-] #{CLI::C}No Modules Specified! Use#{CLI::W} --full #{CLI::C}or a module flag.#{CLI::W}")
          exit(1)
        end

        if enabled[:headers]
          Log.write('Starting header enum...')
          Nokizaru::Modules::Headers.call(target, output, data)
        end

        if enabled[:sslinfo]
          Log.write('Starting SSL enum...')
          Nokizaru::Modules::SSLInfo.call(info[:hostname], info[:ssl_port], output, data)
        end

        if enabled[:whois]
          Log.write('Starting whois enum...')
          Nokizaru::Modules::WhoisLookup.call(info[:domain], info[:suffix], output, data)
        end

        if enabled[:dns]
          Log.write('Starting DNS enum...')
          Nokizaru::Modules::DNSEnumeration.call(info[:hostname], info[:dns_servers], output, data)
        end

        if enabled[:sub]
          if info[:type_ip]
            puts("#{CLI::R}[-] #{CLI::C}Sub-Domain Enumeration is Not Supported for IP Addresses#{CLI::W}\n")
            Log.write('Sub-Domain Enumeration is Not Supported for IP Addresses, exiting')
            exit(1)
          elsif info[:private_ip]
            Log.write('Skipping subdomain enumeration for private IP target')
          else
            Log.write('Starting subdomain enum...')
            Nokizaru::Modules::Subdomains.call(info[:hostname], info[:timeout], output, data, info[:conf_path])
          end
        end

        if enabled[:ps]
          Log.write('Starting port scan...')
          Nokizaru::Modules::PortScan.call(info[:ip], output, data, info[:pscan_threads])
        end

        if enabled[:crawl]
          Log.write('Starting crawler...')
          Nokizaru::Modules::Crawler.call(target, info[:protocol], info[:netloc], output, data)
        end

        if enabled[:dir]
          Log.write('Starting dir enum...')
          Nokizaru::Modules::DirectoryEnum.call(
            target,
            info[:dir_threads],
            info[:timeout],
            info[:wordlist],
            info[:allow_redirects],
            info[:verify_ssl],
            output,
            data,
            info[:extensions]
          )
        end

        if enabled[:wayback]
          Log.write('Starting wayback enum...')
          Nokizaru::Modules::Wayback.call(target, data, output, timeout_s: [info[:timeout].to_f, 10.0].min)
        end

        elapsed = Time.now - start_time
        puts("\n#{CLI::G}[+] #{CLI::C}Completed in #{CLI::W}#{format('%.2f', elapsed)}s\n")
        Log.write("Completed in #{elapsed}s")

        if output && respath
          puts("#{CLI::G}[+] #{CLI::C}Exported : #{CLI::W}#{respath}")
          Log.write("Exported to #{respath}")
        end

        Log.write('-' * 30)
      rescue Interrupt
        puts("#{CLI::R}[-] #{CLI::C}Keyboard Interrupt.#{CLI::W}\n")
        Log.write('Keyboard interrupt, exiting')
        Log.write('-' * 30)
        exit(130)
      end

      private

      def ensure_modules_selected!
        module_flags = %i[full headers sslinfo whois crawl dns sub wayback ps dir]
        return if module_flags.any? { |k| @opts[k] }

        puts("\n#{CLI::R}[-] Error : #{CLI::C}At least one argument is required. Try using --help#{CLI::W}")
        Log.write('At least one argument is required, exiting')
        exit(1)
      end

      def build_output_settings(hostname)
        return [nil, nil] unless @opts[:export]

        output_format = (@opts[:o] || Settings.export_format).to_s

        base = (@opts[:cd] || Paths.user_data_dir).to_s
        base = base.end_with?('/') ? base : (base + '/')

        folder_name = @opts[:of].to_s
        respath = if !folder_name.empty?
                    base + folder_name
                  else
                    dt_now = Time.now.strftime('%d-%m-%Y_%H:%M:%S')
                    base + "nk_#{hostname}_#{dt_now}"
                  end

        FileUtils.mkdir_p(respath)

        output = {
          format: output_format,
          directory: respath,
          file: File.join(respath, "nokizaru.#{output_format}")
        }

        Log.write("OUTPUT = FORMAT: #{output_format}, DIR: #{respath}, FILENAME: #{output[:file]}")
        [output, respath]
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
        netloc = (port && port != default_port) ? "#{hostname}:#{port}" : hostname

        # Resolve IP
        type_ip = ip_literal?(hostname)
        ip = nil
        private_ip = false
        if type_ip
          ip = hostname
          private_ip = IPAddr.new(ip).private?
        else
          begin
            # Socket.gethostbyname(host)[3] returns a raw packed address string (e.g., "\x5D\xB8\xD8\x22"),
            # which prints as gibberish and breaks IPAddr parsing on Ruby 3.3+. Resolve to a real string.
            addrinfos = Addrinfo.getaddrinfo(hostname, nil, :UNSPEC, :STREAM)
            ai = addrinfos.find { |a| a.ip? && a.ipv4? } || addrinfos.find { |a| a.ip? }
            raise "no A/AAAA records" unless ai

            ip = ai.ip_address
            puts("\n#{CLI::G}[+] #{CLI::C}IP Address : #{CLI::W}#{ip}")
            private_ip = IPAddr.new(ip).private?
          rescue StandardError => e
            puts("\n#{CLI::R}[-] #{CLI::C}Unable to Get IP : #{CLI::W}#{e}")
            exit(1)
          end
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
          verify_ssl: @opts[:s].nil? ? Settings.dir_enum_verify_ssl : false,
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

        begin
          parsed = PublicSuffix.parse(hostname)
          [parsed.sld.to_s, parsed.tld.to_s]
        rescue StandardError
          # e.g., localhost
          [hostname.to_s, '']
        end
      end
    end
  end
end
