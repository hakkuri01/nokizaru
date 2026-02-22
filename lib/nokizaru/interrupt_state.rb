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
  end
end
