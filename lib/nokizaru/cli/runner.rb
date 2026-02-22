# frozen_string_literal: true

require_relative 'runner/keys'
require_relative 'runner/findings'
require_relative 'runner/parsing'
require_relative 'runner/parsing_support'
require_relative 'runner/runtime'
require_relative 'runner/workflow'
require_relative 'runner/workspace'
require_relative 'runner/workspace_status'

module Nokizaru
  class CLI
    # Scan runner orchestration class
    class Runner
      include Runner::Keys
      include Runner::Findings
      include Runner::Parsing
      include Runner::ParsingSupport
      include Runner::Runtime
      include Runner::Workflow
      include Runner::Workspace
      include Runner::WorkspaceStatus

      def initialize(options, argv = [])
        @opts = options
        @argv = argv || []
        @skip = parse_skip_flags(@argv)
      end

      def parse_skip_flags(argv)
        names = %w[headers sslinfo whois crawl dns sub arch dir wayback ps]
        names.each_with_object({}) { |name, skip| skip[name.to_sym] = skip_flag?(argv, name) }
      end

      def skip_flag?(argv, name)
        argv.include?("--skip-#{name}") || argv.include?("--no-#{name}")
      end

      private :parse_skip_flags, :skip_flag?
    end
  end
end
