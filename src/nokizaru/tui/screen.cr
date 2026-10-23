require "../terminal_text"

module Nokizaru
  module Tui
    # Draws frames by rewriting only the rows that changed, inside one terminal
    # synchronized update (DEC 2026) so a frame never tears. It remembers the last
    # frame and emits cursor-addressed writes for the rows that differ, clearing
    # any rows the new frame no longer fills.
    class Screen
      def initialize(@output : IO)
        @previous = [] of String
      end

      # Forces a full redraw on the next render (used after a resize, when the
      # whole frame must be laid out again).
      def invalidate : Nil
        @previous = [] of String
      end

      def render(rows : Array(String)) : Nil
        buffer = String.build do |io|
          rows.each_with_index do |row, index|
            next if @previous[index]? == row

            io << "\e[" << (index + 1) << ";1H\e[2K" << row << TerminalText::RESET
          end
          (rows.size...@previous.size).each do |index|
            io << "\e[" << (index + 1) << ";1H\e[2K"
          end
        end
        @previous = rows
        return if buffer.empty?

        @output << "\e[?2026h" << buffer << "\e[?2026l"
        @output.flush
      end
    end
  end
end
