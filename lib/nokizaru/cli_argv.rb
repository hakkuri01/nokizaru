# frozen_string_literal: true

module Nokizaru
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
  end
end
