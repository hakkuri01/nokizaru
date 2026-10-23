module Nokizaru
  module Tui
    # A point-in-time copy of scan progress the dashboard reads while workers keep
    # updating the live rail. The runner's progress rail produces these; the module
    # state carries the phase, a label, and (once the modules report live progress
    # in the runner phase) a stage and detail string the status line renders.
    module Progress
      enum Phase
        Pending
        Running
        Done
        Failed
        Skipped
      end

      record ModuleState,
        phase : Phase,
        label : String,
        stage : String = "",
        detail : String = ""

      record Snapshot,
        enabled_modules : Array(String),
        current_module : String?,
        modules : Hash(String, ModuleState)
    end
  end
end
