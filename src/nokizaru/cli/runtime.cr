require "time"
require "../version"
require "../banner"
require "../run_state"
require "../target_info"
require "../ui"

module Nokizaru::CLI
  # Runtime assembly helpers for the scan runner: the startup banner, the
  # resolved-target context block, the initial typed run state built from the
  # resolved target, and the finalize-time timing stamps. Ports the Ruby
  # Runner::Runtime (plus the banner Ruby kept in Runner::Keys and the target
  # context print Ruby kept in Runner::Parsing). TargetInfo.resolve is pure, so
  # the rendering it deferred lands here; everything is a thin wrapper over the
  # UI sink or a pure value builder, assembled by the Workflow runner.
  module Runtime
    extend self

    AUTHOR = "hakkuri"
    GIT    = "https://github.com/hakkuri01"

    # Prints the classic startup banner: the braille/figlet art, then the author,
    # version, and repo rows. The caller drops it with -nb (and in TUI mode,
    # where the opening scene shows the art instead).
    def banner : Nil
      UI.output.puts("#{UI::R}#{Banner::TEXT}#{UI::W}\n")
      UI.rows(:plus, [{"AUTHOR", AUTHOR.as(String?)}, {"VERSION", Nokizaru::VERSION.as(String?)}])
      UI.row(:plus, "GIT", GIT, label_width: 7)
      UI.blank_line
    end

    # Renders the resolved-target context that the pure TargetInfo.resolve
    # computed but did not print: the unusual scheme/port notice (first, as the
    # Ruby tool emitted it during resolution), then the Target and IP rows, with
    # an unresolved host shown with its resolution error.
    def present_target(info : TargetInfo) : Nil
      notice = info.notice
      UI.row(:info, "Target Notice", notice) unless notice.nil?
      error = info.ip_resolution_error
      ip_display = info.ip || "unresolved (#{error})"
      UI.rows(:info, [{"Target", info.target.as(String?)}, {"IP Address", ip_display.as(String?)}])
    end

    # Builds the initial run state from the resolved target: version, target,
    # resolved hostname and ip (null when unresolved), and the UTC start stamp.
    # modules, artifacts, and findings start empty and fill as the scan runs.
    def initial_run_state(info : TargetInfo, started_at : Time = Time.utc) : RunState
      meta = Meta.new(
        version: Nokizaru::VERSION,
        target: info.target,
        hostname: info.hostname,
        ip: info.ip,
        started_at: started_at.to_utc.to_rfc3339,
      )
      RunState.new(meta)
    end

    # Stamps the finish time and elapsed seconds on the run meta and returns the
    # elapsed seconds (unrounded, as the Ruby tool left it). Called once at
    # finalize; now is a parameter so the stamping is deterministic in a test.
    def finalize_timing(run : RunState, started_at : Time, now : Time = Time.utc) : Float64
      elapsed = (now - started_at).total_seconds
      run.meta.ended_at = now.to_utc.to_rfc3339
      run.meta.elapsed_s = elapsed
      elapsed
    end
  end
end
