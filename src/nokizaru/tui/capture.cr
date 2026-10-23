require "../terminal_text"

module Nokizaru
  module Tui
    # Stands in for the UI output sink during a scan: every complete line written
    # becomes a callback, so modules print as usual while the dashboard captures
    # them. A multi-line colored write keeps its color on each line, as a terminal
    # would. Writes arrive on the scan fiber one at a time, so no lock is needed.
    class Capture < IO
      MAX_PENDING_BYTES = 4096

      def initialize(@on_line : String -> Nil)
        @pending = IO::Memory.new
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("Capture is write-only")
      end

      def write(slice : Bytes) : Nil
        return if slice.empty?

        @pending.write(slice)
        drain
      end

      private def drain : Nil
        data = @pending.to_slice
        newline = data.rindex(0x0A_u8)
        if newline
          # Copy out before clearing: the slices view the buffer being reset.
          complete = String.new(data[0, newline])
          remainder = data[(newline + 1)..].dup
          @pending.clear
          emit(complete)
          carry_remainder(remainder)
        elsif data.size > MAX_PENDING_BYTES
          text = String.new(data)
          @pending.clear
          emit(text)
        end
      end

      # An endless line without a newline is released at the cap instead of growing
      # without bound.
      private def carry_remainder(remainder : Bytes) : Nil
        return if remainder.empty?

        if remainder.size > MAX_PENDING_BYTES
          emit(String.new(remainder))
        else
          @pending.write(remainder)
        end
      end

      private def emit(text : String) : Nil
        carry = ""
        text.split('\n').each do |line|
          safe = TerminalText.utf8(line)
          full = carry.empty? ? safe : "#{carry}#{safe}"
          @on_line.call(full)
          carry = TerminalText.active_sgr(full)
        end
      end
    end
  end
end
