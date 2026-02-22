# frozen_string_literal: true

module Nokizaru
  # Class-level CLI help and boot behavior
  module CLIClassInterface
    HELP_USAGE = <<~USAGE
      usage: nokizaru [-h] [-v] [--url URL] [--headers] [--sslinfo] [--whois] [--crawl] [--dns] [--sub] [--arch] [--dir] [--wayback] [--wb-raw] [--ps]
                      [--full] [--no-MODULE] [--export] [--project NAME] [--cache] [--no-cache] [--diff last or ID] [-nb] [-dt DT] [-pt PT] [-T T] [-w W] [-r] [-s] [-sp SP] [-d D] [-e E] [-o O] [-cd CD] [-of OF] [-k K]
    USAGE

    HELP_ARGUMENT_ROWS = [
      ['-h, --help', 'Show this help message and exit'], ['-v, --version', 'Show version number and exit'],
      ['--url URL', 'Target URL'], ['--headers', 'Header Information'],
      ['--sslinfo', 'SSL Certificate Information'], ['--whois', 'Whois Lookup'], ['--crawl', 'Crawl Target'],
      ['--dns', 'DNS Enumeration'], ['--sub', 'Sub-Domain Enumeration'], ['--arch', 'Architecture Fingerprinting'],
      ['--dir', 'Directory Search'], ['--wayback', 'Wayback URLs'],
      ['--wb-raw', 'Wayback raw URL output (no quality filtering)'],
      ['--ps', 'Fast Port Scan'], ['--full', 'Full Recon'],
      ['--no-[MODULE]', 'Skip specified modules above during full scan (eg. --no-dir)'],
      ['--export', 'Write results to export directory [ Default : False ]'],
      ['--project [NAME]', 'Enable a persistent workspace (profiles, caching, diffing)'],
      ['--cache', 'Enable caching even without a project'],
      ['--no-cache', 'Disable caching (even in a project)'],
      ['--diff last / [ID]', 'Diff this run against the last (or another run ID in the workspace)']
    ].freeze

    HELP_EXTRA_ROWS = [
      ['-nb', 'Hide Banner'], ['-dt DT', 'Number of threads for directory enum [ Default : 30 ]'],
      ['-pt PT', 'Number of threads for port scan [ Default : 50 ]'],
      ['-T T', 'Request Timeout [ Default : 30.0 ]'],
      ['-w W', 'Path to Wordlist [ Default : wordlists/dirb_common.txt ]'],
      ['-r', 'Allow Redirect [ Default : False ]'], ['-s', 'Toggle SSL Verification [ Default : True ]'],
      ['-sp SP', 'Specify SSL Port [ Default : 443 ]'], ['-d D', 'Custom DNS Servers [ Default : 1.1.1.1 ]'],
      ['-e E', 'File Extensions [ Example : txt, xml, php, etc. ]'],
      ['-o O', 'Export Formats (comma-separated) [ Default : txt,json,html ]'],
      ['-cd CD', 'Change export directory (requires --export) [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]'],
      ['-of OF', 'Change export folder name (requires --export) [ Default : YYYY-MM-DD_HH-MM-SS ]'],
      ['-k K', 'Add API key [ Example : shodan@key ]']
    ].freeze

    def start(given_args = ARGV, config = {})
      args = Array(given_args).dup
      return print_version_and_exit if version_invocation?(args)
      return handle_help_start(args) if help_invocation?(args)

      super(args, config)
    end

    def version_invocation?(args)
      args.length == 1 && ['--version', '-v'].include?(args[0])
    end

    def help_invocation?(args)
      args.include?('--help') || args.include?('-h') || args[0] == 'help'
    end

    def print_version_and_exit
      puts "nokizaru #{VERSION}"
      exit(0)
    end

    def handle_help_start(args)
      return print_help_and_exit if valid_help_syntax?(args)

      warn_invalid_help_syntax
      exit(1)
    end

    def valid_help_syntax?(args)
      args.length == 1 && ['--help', '-h', 'help'].include?(args[0])
    end

    def warn_invalid_help_syntax
      warn("#{UI.prefix(:error)} #{CLI::C}Invalid help syntax#{CLI::W}")
      warn(
        "#{UI.prefix(:plus)} #{CLI::C}Use #{CLI::W}nokizaru --help#{CLI::C} " \
        "(or #{CLI::W}-h#{CLI::C}) to view the full CLI documentation#{CLI::W}"
      )
    end

    def print_help_and_exit
      shell_klass = Thor::Base.shell || Thor::Shell::Color
      help(shell_klass.new)
      exit(0)
    end

    def handle_no_command_error(command, _has_namespace: false)
      warn("#{UI.prefix(:error)} #{CLI::C}Unknown command : #{CLI::W}#{command}#{CLI::W}")
      warn("#{UI.prefix(:plus)} #{CLI::C}Use #{CLI::W}nokizaru --help#{CLI::C} to view valid flags and usage#{CLI::W}")
      exit(1)
    end

    def help(shell, _subcommand: false)
      shell.say(HELP_USAGE.rstrip)
      shell.say('')
      shell.say("Nokizaru - Recon Refined | v#{VERSION}")
      shell.say('')
      shell.say('Arguments:')
      print_aligned_rows(shell, HELP_ARGUMENT_ROWS)
      shell.say('')
      shell.say('Extra Options:')
      print_aligned_rows(shell, HELP_EXTRA_ROWS)
      shell.say('')
    end

    def print_aligned_rows(shell, rows)
      left_width = [rows.map { |(left, _)| left.length }.max || 0, 18].max
      rows.each { |left, right| shell.say(format("  %-#{left_width}s %s", left, right)) }
    end
  end
end
