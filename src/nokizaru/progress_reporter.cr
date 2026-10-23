module Nokizaru
  # A module's handle for publishing live progress. Modules format their own
  # stage/detail strings (the rail colors and renders them), so no module depends
  # on the rail or a global. The default NULL reporter is a no-op, so a module runs
  # identically with or without a rail attached (and in isolation tests). The
  # Crystal way: progress is injected, not reached for.
  class ProgressReporter
    def initialize(@sink : Proc(String, String, Nil)? = nil)
    end

    def report(stage : String = "", detail : String = "") : Nil
      @sink.try &.call(stage, detail)
    end

    # Whether a real sink is attached. Modules check this to skip formatting a
    # live-progress string (and any lock it needs) when no rail is listening.
    def active? : Bool
      !@sink.nil?
    end

    NULL = ProgressReporter.new
  end
end
