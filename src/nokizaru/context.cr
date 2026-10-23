require "./run_state"

module Nokizaru
  # The in-memory scan context shared across modules. Holds the typed run state;
  # the injected clock, HTTP transport, and resolver, plus the progress rail and
  # parsed options, attach in later phases. A class (reference type) so modules
  # mutate one shared run.
  class Context
    getter run : RunState

    def initialize(@run : RunState)
    end

    def add_artifact(kind : String, values : Enumerable(String)) : Nil
      @run.add_artifact(kind, values)
    end
  end
end
