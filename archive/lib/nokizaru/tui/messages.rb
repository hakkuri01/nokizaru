# frozen_string_literal: true

module Nokizaru
  module TUI
    # The values the model updates on, one per event the program loop observes
    module Messages
      Key = Data.define(:name)
      Resize = Data.define(:cols, :rows)
      Tick = Data.define(:now, :snapshot, :statuses)
      Lines = Data.define(:items)
      ScanStarted = Data.define(:profile)
      ScanDone = Data.define(:elapsed, :export_dir, :status)
      ScanFailed = Data.define(:reason)
      ScanAborted = Data.define(:reason)
    end
  end
end
