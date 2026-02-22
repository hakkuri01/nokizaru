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
require_relative 'cli/class_interface'
require_relative 'cli/options'

module Nokizaru
  # Nokizaru::CLI implementation
  class CLI < Thor
    extend CLIClassInterface
    extend CLIOptions

    require_relative 'cli/runner'

    R = "\e[31m"
    G = "\e[32m"
    C = "\e[36m"
    W = "\e[0m"

    remove_command :help if respond_to?(:remove_command)

    desc 'help', 'Show Nokizaru help'
    def help(*args)
      if args.any?
        UI.line(:error, 'Invalid help syntax')
        UI.line(:plus, 'Use nokizaru --help to view the full CLI documentation')
        exit(1)
      end

      self.class.help(shell)
    end

    default_task :scan

    def self.exit_on_failure?
      true
    end

    desc 'scan', "Nokizaru - Recon Refined | v#{VERSION}"
    apply_scan_options(self)

    def scan(*args)
      unless args.empty?
        bad = args.join(' ')
        UI.line(:error, "Invalid syntax. Unexpected argument(s) : #{bad}")
        UI.line(:plus, 'If you meant export formats, use -o with comma-separated formats')
        UI.line(:plus, 'Example : nokizaru --headers --url https://example.com --export -o txt,json,html')
        UI.line(:plus, 'Tip : --export is a flag (no positional values)')
        exit(1)
      end

      Runner.new(options, ::ARGV.dup).run
    end
  end
end
