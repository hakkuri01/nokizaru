require "../log"
require "../terminal_text"
require "../tui/progress"
require "../ui"
require "./workflow"

module Nokizaru::CLI
  # The no-TUI runner (--headless): the same Workflow with its module report muted,
  # the JSON result on stdout (unless --export wrote files), and plain lifecycle
  # lines on stderr, escape-stripped because a failure reason can quote the target.
  class Headless
    INTERRUPTED = 130 # 128 + SIGINT, the shell's status for a run cut short

    def initialize(@workflow : Workflow, *, @sink : IO, @log : IO)
      @interrupted = false
    end

    def run : Int32
      UI.muted do
        plan = @workflow.plan!(->progress(String, Tui::Progress::Phase, String))
        plan.info.notice.try { |notice| @log.puts("notice: #{TerminalText.plain(notice)}") }
        elapsed, export_dir = with_interrupt_trap do
          @workflow.execute!(plan)
          @workflow.finalize!(plan)
        end
        emit(plan.state, elapsed, export_dir)
        @interrupted ? INTERRUPTED : 0
      end
    rescue error : Workflow::Error | TargetInfo::Error
      report_error(error.message || "scan failed")
    rescue error
      Log.write("[headless] #{error.class}: #{error.message}")
      report_error("unexpected #{error.class}; details are in the runtime log")
    end

    # The first SIGINT, SIGHUP, or SIGTERM stops the scan cooperatively, so what
    # finished still reaches the output; the module in flight can take up to its
    # budget to end, so a second signal exits at once.
    private def with_interrupt_trap(&)
      Process.on_terminate { interrupt }
      yield
    ensure
      Process.restore_interrupts!
    end

    private def interrupt : Nil
      exit INTERRUPTED if @interrupted
      @interrupted = true
      @workflow.stop.stop!
      @log.puts("interrupted: finishing the module in flight; signal again to exit now")
    end

    private def progress(key : String, phase : Tui::Progress::Phase, reason : String) : Nil
      line = "[#{key}] #{phase.to_s.downcase}"
      @log.puts(reason.empty? ? line : "#{line}: #{TerminalText.plain(reason)}")
    end

    # finalize! already wrote any --export files, so only a plain run prints the JSON
    private def emit(state : RunState, elapsed : Float64, export_dir : String?) : Nil
      if export_dir
        @log.puts("exported to #{TerminalText.plain(export_dir)}")
      else
        state.to_pretty_json(@sink)
        @sink.puts
      end
      @log.puts("completed in #{"%.2f" % elapsed}s")
    end

    private def report_error(message : String) : Int32
      @log.puts("error: #{TerminalText.plain(message)}")
      1
    end
  end
end
