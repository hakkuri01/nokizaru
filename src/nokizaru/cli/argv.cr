module Nokizaru::CLI
  # Crystal's OptionParser only accepts single-character short flags, so the
  # multi-character short flags (-nb, -dt, -pt, -sp, -cd, -of) are rewritten to
  # their long forms before parsing. The user still types the short form; the
  # grammar and help are unchanged.
  module Argv
    extend self

    SHORT_FLAGS = {
      "-nb" => "--nb", "-dt" => "--dt", "-pt" => "--pt",
      "-sp" => "--sp", "-cd" => "--cd", "-of" => "--of",
    }

    def normalize(argv : Array(String)) : Array(String)
      argv.map { |arg| normalize_arg(arg) }
    end

    def normalize_arg(arg : String) : String
      return SHORT_FLAGS[arg] if SHORT_FLAGS.has_key?(arg)

      SHORT_FLAGS.each do |short, long|
        return "#{long}#{arg[short.size..]}" if arg.starts_with?("#{short}=")
      end
      arg
    end
  end
end
