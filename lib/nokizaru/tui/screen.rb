# frozen_string_literal: true

module Nokizaru
  module TUI
    # Draws frames by rewriting only the rows that changed, inside one synchronized update
    class Screen
      def initialize(output)
        @output = output
        @previous = []
      end

      def invalidate
        @previous = []
      end

      def render(rows)
        buffer = +''
        rows.each_with_index do |row, index|
          buffer << "\e[#{index + 1};1H\e[2K" << row << TerminalText::RESET unless @previous[index] == row
        end
        (rows.length...@previous.length).each { |index| buffer << "\e[#{index + 1};1H\e[2K" }
        @previous = rows
        return if buffer.empty?

        @output.write("\e[?2026h#{buffer}\e[?2026l")
      end
    end
  end
end
