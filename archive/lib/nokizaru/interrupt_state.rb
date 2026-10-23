# frozen_string_literal: true

module Nokizaru
  # Tracks process interrupt state across CLI and worker modules
  module InterruptState
    module_function

    def interrupted?
      @interrupted == true
    end

    def interrupt!
      @interrupted = true
    end

    # Clears the flag so a fresh scan from the interactive app is not born already interrupted
    def reset!
      @interrupted = false
    end
  end
end
