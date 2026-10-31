require "../run_state"
require "../scan_stop"
require "../target_info"
require "../settings"
require "../banner"
require "../ui"
require "../dns/resolver"
require "../tui/progress"
require "../tui/profile"
require "../tui/messages"
require "../tui/feed"
require "../tui/capture"
require "../tui/form"
require "../tui/app"
require "../tui/dashboard"
require "../tui/terminal"
require "../tui/program"
require "./options"
require "./workflow"

module Nokizaru::CLI
  # The interactive controller: bridges the TUI program loop to the scan runner.
  # It builds the form/app/program, then on launch runs a Workflow on a background
  # fiber, capturing module output into a Feed and exposing the live progress rail
  # and per-module statuses to the dashboard. Implements the Program's duck-typed
  # controller contract (wake_channel / scanning? / run_scan / stop_scan / observe
  # / feed). The scan fiber plus channels replace the Ruby thread and self-pipe.
  class Session
    getter wake_channel : Channel(Nil)

    @feed : Tui::Feed?
    @plan : Workflow::Plan?
    @launched_workflow : Workflow?
    @stop : ScanStop?
    @clock : -> Float64

    def initialize(
      @options : Options,
      @settings : Settings = Settings.new,
      @resolve_ip : Proc(String, String?) = ->(host : String) { Dns::Resolver.new.resolve(host) },
      clock : (-> Float64)? = nil,
    )
      @wake_channel = Channel(Nil).new(1)
      @scanning = false
      @generation = 0
      @feed = nil
      @plan = nil
      @launched_workflow = nil
      epoch = Time.instant
      @clock = clock || -> { (Time.instant - epoch).total_seconds }
    end

    # Marks this a power-user launch: the dashboard opens directly on the
    # pre-validated plan and the scan auto-starts, with no opener or form. The
    # caller has already run plan! (so a bad invocation failed classically before
    # the terminal opened); this session reuses that plan rather than re-planning.
    def launch!(workflow : Workflow, plan : Workflow::Plan) : Nil
      @launched_workflow = workflow
      @plan = plan
    end

    # Runs the interactive dashboard to completion and returns the process exit
    # status (0, or a signal-derived status from the loop).
    def run : Int32
      UI.tui_mode = true
      form = Tui::Form.new(@options)
      planned = @plan
      launch_profile = planned.nil? ? nil : dashboard_profile(planned)
      app = Tui::App.new(form, Banner::TEXT.lines, @clock.call, opening: !@options.nb?, launch: launch_profile)
      start_launched_scan
      terminal = Tui::Terminal.new
      program = Tui::Program(Session).new(app, terminal, self, @clock)
      program.run
      program.signal_status || 0
    ensure
      UI.tui_mode = false
      UI.output = STDOUT
    end

    def scanning? : Bool
      @scanning
    end

    def feed : Tui::Feed?
      @feed
    end

    # The live progress snapshot plus the per-module recorded statuses the
    # dashboard uses to color done tabs (a no-key skip, a self-reported failure).
    def observe : {Tui::Progress::Snapshot?, Hash(String, String)}
      plan = @plan
      return {nil, {} of String => String} if plan.nil?

      {plan.rail.snapshot, module_statuses(plan.state)}
    end

    # Launches a scan for the app's composed options on a background fiber.
    def run_scan(app : Tui::App) : Nil
      return if @scanning

      generation = @generation += 1
      stop = ScanStop.new
      @stop = stop
      feed = install_feed(generation)
      @scanning = true
      options = app.scan_options
      spawn do
        scan(options, feed, stop, generation)
      ensure
        finish(generation)
      end
    end

    # Module output flows through a Capture into this scan's Feed; setup output
    # (target context) is held as prelude until the scan goes live. UI.output is
    # process wide and a stopped scan's fiber can still be winding down, so a line
    # from an older generation is dropped rather than mixed into this scan.
    private def install_feed(generation : Int32) : Tui::Feed
      feed = Tui::Feed.new(-> { @plan.try(&.rail.current_module) }, -> { nudge })
      @feed = feed
      UI.output = Tui::Capture.new(->(line : String) { feed.line(line) if generation == @generation })
      feed
    end

    # Stopping is cooperative, because Crystal has no fiber cancellation: the flag
    # the long loops poll goes up, the module runner starts nothing further, and
    # the generation moves so a late line from the stopped fiber is dropped
    # instead of landing in the next scan's dashboard.
    def stop_scan : Nil
      @stop.try(&.stop!)
      @generation += 1
      @scanning = false
    end

    private def scan(options : Options, feed : Tui::Feed, stop : ScanStop, generation : Int32) : Nil
      workflow = Workflow.new(options, @settings, @resolve_ip, stop)
      plan = workflow.plan!
      @plan = plan if generation == @generation
      feed.event(Tui::Messages::ScanStarted.new(dashboard_profile(plan)))
      run_plan(workflow, plan, feed, stop)
    rescue error
      report_failure(feed, error)
    end

    # The shared scan body. A scan the operator stopped skips finalize, so an
    # abandoned run writes no export and prints no completion line.
    private def run_plan(workflow : Workflow, plan : Workflow::Plan, feed : Tui::Feed, stop : ScanStop) : Nil
      feed.live!
      workflow.execute!(plan)
      return if stop.stopped?

      feed.tag = "summary" # findings and the completion line belong to Summary
      elapsed, export_dir = workflow.finalize!(plan)
      feed.event(Tui::Messages::ScanDone.new(elapsed, export_dir, 0))
    end

    private def finish(generation : Int32) : Nil
      @scanning = false if generation == @generation
      nudge
    end

    # Starts the pre-planned power-user scan. The dashboard is already open
    # on the plan's profile, so the feed goes live immediately and no ScanStarted
    # is emitted; the fiber runs execute!/finalize! on the plan built up front. A
    # no-op unless launch! armed the session.
    private def start_launched_scan : Nil
      workflow = @launched_workflow
      plan = @plan
      return if workflow.nil? || plan.nil?

      generation = @generation += 1
      @stop = workflow.stop
      feed = install_feed(generation)
      @scanning = true
      spawn do
        launched_scan(workflow, plan, feed)
      ensure
        finish(generation)
      end
    end

    private def launched_scan(workflow : Workflow, plan : Workflow::Plan, feed : Tui::Feed) : Nil
      run_plan(workflow, plan, feed, workflow.stop)
    rescue error
      report_failure(feed, error)
    end

    # reason; one that raised after going live fails on the dashboard. A fatal
    # carries its own message (bad target, bad export option); an unexpected raise
    # with no message falls back to the last setup line.
    private def report_failure(feed : Tui::Feed, error : Exception) : Nil
      message = error.message
      message = nil if message && message.empty?
      if feed.live?
        feed.event(Tui::Messages::ScanFailed.new(message || "Scan failed"))
      else
        feed.event(Tui::Messages::ScanAborted.new(message || feed.prelude_error))
      end
    end

    private def dashboard_profile(plan : Workflow::Plan) : Tui::Profile
      info = plan.info
      Tui::Profile.new(
        target: info.target,
        ip: info.ip || "unresolved",
        modules: plan.enabled.map { |key| Tui::Dashboard::LABELS[key]? || key }.join(", "),
        switches: switches_summary(info),
        modules_enabled: plan.enabled,
        notice: info.notice,
      )
    end

    # A compact switches line for the HUD. Custom headers are shown only as a
    # count, never their values, so no secret reaches the dashboard.
    private def switches_summary(info : TargetInfo) : String
      parts = [] of String
      parts << "redirects" if info.allow_redirects?
      parts << "insecure-tls" unless info.verify_ssl?
      parts << "export" if @options.export?
      parts << "headers:#{info.request_headers.size}" unless info.request_headers.empty?
      parts << "wordlist:#{info.wordlist}"
      parts.join(", ")
    end

    private def module_statuses(state : RunState) : Hash(String, String)
      statuses = {} of String => String
      state.modules.arch.try { |result| statuses["arch"] = result.status }
      state.modules.crawler.try { |result| statuses["crawl"] = result.status }
      state.modules.wayback.try { |result| statuses["wayback"] = result.status }
      statuses
    end

    # Coalesced wake: a non-blocking send, so a burst of feed writes nudges the
    # loop at most once per pending slot and never blocks the scan fiber.
    private def nudge : Nil
      select
      when @wake_channel.send(nil)
      else
        # a wake is already queued; the loop will pick it up on its next turn
      end
    end
  end
end
