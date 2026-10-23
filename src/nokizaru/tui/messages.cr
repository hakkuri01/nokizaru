require "./progress"
require "./profile"

module Nokizaru
  module Tui
    # The values the interactive model updates on, one per event the program loop
    # observes.
    module Messages
      # A decoded keypress: a key name ("up", "enter", "ctrl+c", "esc") or the
      # literal character typed.
      record Key, name : String

      # A new terminal size, cells wide by rows tall.
      record Resize, cols : Int32, rows : Int32

      # One captured scan-output line, tagged with the module it belongs to (nil
      # routes it to the Summary tab).
      record FeedLine, tag : String?, text : String

      # A batch of captured lines drained from the feed in one tick.
      record Lines, items : Array(FeedLine)

      # A loop tick: the clock, a progress snapshot (nil before the scan goes
      # live), and the per-module recorded statuses.
      record Tick, now : Float64, snapshot : Progress::Snapshot?, statuses : Hash(String, String)

      # The scan went live: the planned run profile, which opens the dashboard.
      record ScanStarted, profile : Profile

      # The scan finished: wall-clock seconds, the export directory if one was
      # written, and the process exit status.
      record ScanDone, elapsed : Float64?, export_dir : String?, status : Int32

      # The scan raised before or during the run; reason is shown on the dashboard.
      record ScanFailed, reason : String

      # A launch stopped before the scan went live; reason is shown back on the form.
      record ScanAborted, reason : String

      # The scan-lifecycle events the feed carries from the scan fiber to the loop.
      alias LifecycleEvent = ScanStarted | ScanDone | ScanFailed | ScanAborted

      # The messages the program loop dispatches to the model.
      alias Message = Key | Resize | Lines | Tick | ScanStarted | ScanDone | ScanFailed | ScanAborted
    end
  end
end
