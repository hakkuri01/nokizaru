require "option_parser"
require "./cli/options"
require "./cli/help"
require "./cli/key_saver"
require "./cli/workflow"
require "./cli/session"
require "./settings"
require "./target_info"
require "./ui"

module Nokizaru
  # The command-line entrypoint: parses argv, handles --help/--version and the
  # -k key-save flow, then runs either the interactive dashboard (on a terminal
  # or with --tui) or a classic one-shot scan. Returns the process exit status.
  # Ports the Ruby CLI dispatch; `interactive` and `io` are injected so the
  # routing is testable without a terminal.
  module CLI
    HELP_FLAGS    = {"-h", "--help"}
    VERSION_FLAGS = {"-v", "--version"}

    def self.start(argv : Array(String), interactive : Bool = STDOUT.tty?, io : IO = STDOUT) : Int32
      return render_help(io) if argv.any? { |arg| HELP_FLAGS.includes?(arg) }
      return render_version(io) if argv.any? { |arg| VERSION_FLAGS.includes?(arg) }

      options = Options.parse(argv)
      settings = Settings.load
      key = options.key
      return KeySaver.run(key) unless key.nil?

      run_scan(options, settings, interactive)
    rescue error : OptionParser::Exception
      UI.line(:error, error.message || "Invalid arguments")
      2
    end

    private def self.render_help(io : IO) : Int32
      Help.render(io)
      0
    end

    private def self.render_version(io : IO) : Int32
      io.puts(Help.version)
      0
    end

    private def self.run_scan(options : Options, settings : Settings, interactive : Bool) : Int32
      if interactive || options.tui?
        return run_power_user(options, settings) if interactive && power_user_args?(options)

        return Session.new(options, settings).run
      end

      run_classic(options, settings)
    end

    # The power-user gate (§12a, T6): a --target on a terminal, without the --tui
    # opt-out that keeps the interactive form.
    private def self.power_user_args?(options : Options) : Bool
      !options.tui? && !(options.target || "").strip.empty?
    end

    # Validates the launch up front (so a bad invocation prints the classic error
    # and exits before the terminal opens), then hands the ready plan to a session
    # that opens straight on the running dashboard. plan! output is muted here so
    # nothing leaks to the terminal ahead of the alternate screen.
    private def self.run_power_user(options : Options, settings : Settings) : Int32
      workflow = Workflow.new(options, settings)
      plan = plan_quietly(workflow)
      session = Session.new(options, settings)
      session.launch!(workflow, plan)
      session.run
    rescue error : Workflow::Error | TargetInfo::Error
      UI.line(:error, error.message || "Scan failed")
      1
    end

    private def self.plan_quietly(workflow : Workflow) : Workflow::Plan
      original = UI.output
      UI.output = IO::Memory.new
      begin
        workflow.plan!
      ensure
        UI.output = original
      end
    end

    private def self.run_classic(options : Options, settings : Settings) : Int32
      Workflow.new(options, settings).run
      0
    rescue error : Workflow::Error | TargetInfo::Error
      UI.line(:error, error.message || "Scan failed")
      1
    end
  end
end
