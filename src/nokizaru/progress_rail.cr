require "./tui/progress"
require "./progress_reporter"

module Nokizaru
  # The live scan progress shared across modules: each enabled module's phase and
  # a module-formatted stage/detail, updated fiber-safely as modules report, while
  # the dashboard reads immutable snapshots. The Crystal way: modules publish
  # through an injected `reporter`, and the loop reads snapshots, so there is no
  # global and no ticker thread (the TUI loop drives rendering).
  class ProgressRail
    private class Live
      property phase : Tui::Progress::Phase
      property label : String
      property stage : String
      property detail : String

      def initialize(@phase : Tui::Progress::Phase, @label : String, @stage = "", @detail = "")
      end
    end

    def initialize(@enabled : Array(String))
      @current = @enabled.first?
      @mutex = Mutex.new
      @modules = {} of String => Live
      @enabled.each { |key| @modules[key] = Live.new(Tui::Progress::Phase::Pending, key) }
    end

    # The handle a module publishes through. Reporting updates the module's own
    # stage without claiming focus; only a lifecycle event moves the rail.
    def reporter(key : String) : ProgressReporter
      ProgressReporter.new(->(stage : String, detail : String) {
        update(key) { |live| live.stage = stage; live.detail = detail }
      })
    end

    def module_started(key : String, label : String) : Nil
      set(key) { |live| live.phase = Tui::Progress::Phase::Running; live.label = label }
    end

    def module_finished(key : String) : Nil
      update(key, &.phase=(Tui::Progress::Phase::Done))
    end

    def module_failed(key : String) : Nil
      update(key, &.phase=(Tui::Progress::Phase::Failed))
    end

    def module_skipped(key : String, label : String) : Nil
      set(key) { |live| live.phase = Tui::Progress::Phase::Skipped; live.label = label }
    end

    def current_module : String?
      @mutex.synchronize { @current }
    end

    # A copy the dashboard reads while workers keep updating.
    def snapshot : Tui::Progress::Snapshot
      @mutex.synchronize do
        modules = {} of String => Tui::Progress::ModuleState
        @modules.each do |key, live|
          modules[key] = Tui::Progress::ModuleState.new(live.phase, live.label, live.stage, live.detail)
        end
        Tui::Progress::Snapshot.new(@enabled, @current, modules)
      end
    end

    private def set(key : String, & : Live -> _) : Nil
      @mutex.synchronize do
        @current = key
        live = @modules[key] ||= Live.new(Tui::Progress::Phase::Pending, key)
        yield live
      end
    end

    # Phase and stage changes that must not move the current module: a module
    # abandoned after its timeout can still report, and its late lines must not
    # retag the output of the module running now.
    private def update(key : String, & : Live -> _) : Nil
      @mutex.synchronize do
        live = @modules[key] ||= Live.new(Tui::Progress::Phase::Pending, key)
        yield live
      end
    end
  end
end
