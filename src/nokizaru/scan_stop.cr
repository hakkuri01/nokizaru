module Nokizaru
  # The cooperative stop signal for a running scan. Crystal has no fiber
  # cancellation, so the loops that can outlive a dashboard (directory
  # enumeration, the port scan) poll this between units of work and the module
  # runner starts nothing further once it is set: the dashboard's `q` has to stop
  # sending requests, not just stop showing them. A module already in flight
  # still finishes or hits its own budget, so a stop lands within one module's
  # timeout rather than instantly.
  class ScanStop
    def initialize
      @flag = Atomic(Int32).new(0)
    end

    def stop! : Nil
      @flag.set(1)
    end

    def stopped? : Bool
      @flag.get != 0
    end
  end
end
