# frozen_string_literal: true

module Nokizaru
  # Normalizes command line arguments before Thor parses them
  module CLIArgv
    module_function

    SHORT_FLAG_REPLACEMENTS = {
      '-nb' => '--nb',
      '-dt' => '--dt',
      '-pt' => '--pt',
      '-sp' => '--sp',
      '-cd' => '--cd',
      '-of' => '--of'
    }.freeze

    def normalize_argv!(argv)
      argv.map! { |arg| normalize_arg(arg) }
    end

    def normalize_help_invocation!(argv)
      if command_help_invocation?(argv)
        argv.replace(%w[help scan])
        return
      end

      return unless global_help_scan_invocation?(argv)

      argv.replace(%w[help scan])
      nil
    end

    def normalize_arg(arg)
      return SHORT_FLAG_REPLACEMENTS[arg] if SHORT_FLAG_REPLACEMENTS.key?(arg)

      normalize_assignment_flag(arg) || arg
    end

    def normalize_assignment_flag(arg)
      found = SHORT_FLAG_REPLACEMENTS.find { |flag, _| arg.start_with?("#{flag}=") }
      return nil unless found

      flag, long_flag = found
      "#{long_flag}#{arg[flag.length..]}"
    end

    def command_help_invocation?(argv)
      command = argv[0]
      return false unless command && %w[scan run].include?(command)

      argv.include?('--help') || argv.include?('-h')
    end

    def global_help_scan_invocation?(argv)
      argv[0] && %w[--help -h].include?(argv[0]) && argv[1] == 'scan'
    end
  end
end
