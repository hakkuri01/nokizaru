# frozen_string_literal: true

require 'stringio'

module Nokizaru
  module TUI
    # Stands in for $stdout or $stderr: every complete line written becomes a callback, so modules print as usual
    class Capture < StringIO
      MAX_PENDING_BYTES = 4096

      def initialize(stream, on_line)
        super()
        @stream = stream
        @on_line = on_line
        @key = :"nokizaru_capture_#{stream}"
      end

      # Partial lines wait per fiber, so writers never share a buffer and no lock is needed (traps stay safe)
      # ponytail: a partial line left in another thread's buffer when the session ends is dropped; UI writes whole lines
      def write(*parts)
        text = parts.map { |part| part.to_s.b }.join
        pending = Thread.current[@key]
        text = pending << text if pending
        lines = text.split("\n", -1)
        rest = lines.pop.to_s
        emit(lines)
        Thread.current[@key] = hold(rest)
        text.bytesize
      end

      def tty?
        true
      end
      alias isatty tty?

      private

      # An endless line without a newline is released at the cap instead of growing without bound
      def hold(rest)
        return nil if rest.empty?
        return emit([rest]) if rest.bytesize > MAX_PENDING_BYTES

        rest
      end

      # A multi-line colored write (the banner) keeps its color on every line, as it would in a terminal
      def emit(lines)
        carry = +''
        lines.each do |line|
          text = TerminalText.utf8(line)
          full = carry.empty? ? text : carry + text
          @on_line.call(@stream, full)
          carry = TerminalText.active_sgr(full)
        end
        nil
      end
    end
  end
end
