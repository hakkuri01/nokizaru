# frozen_string_literal: true

module Nokizaru
  module TUI
    # Where each part of the dashboard sits for a terminal size: full HUD, compact, or too small
    module Layout
      Geometry = Data.define(:mode, :cols, :rows, :branches, :tab_row, :rule_row, :pane_top, :pane_height,
                             :pane_left, :pane_width, :status_row)

      FULL_MIN = [80, 24].freeze
      COMPACT_MIN = [50, 12].freeze

      module_function

      def measure(cols, rows, branches, footers: 1)
        return full(cols, rows, branches, footers) if cols >= FULL_MIN[0] && rows >= FULL_MIN[1]
        return compact(cols, rows) if cols >= COMPACT_MIN[0] && rows >= COMPACT_MIN[1]

        Geometry.new(mode: :tiny, cols: cols, rows: rows, branches: 0, tab_row: nil, rule_row: nil, pane_top: 0,
                     pane_height: 0, pane_left: 0, pane_width: 0, status_row: nil)
      end

      # Top cluster (head rail, identity, branches), a trunk row, tabs, rule, pane, then the bottom cluster:
      # one branch row per readout, the cheatsheet rail, and the corner
      def full(cols, rows, branches, footers)
        top_rows = 2 + branches
        pane_top = top_rows + 3
        status_row = rows - (footers + 2)
        Geometry.new(mode: :full, cols: cols, rows: rows, branches: branches, tab_row: top_rows + 1,
                     rule_row: top_rows + 2, pane_top: pane_top, pane_height: status_row - pane_top,
                     pane_left: 3, pane_width: cols - 6, status_row: status_row)
      end

      def compact(cols, rows)
        Geometry.new(mode: :compact, cols: cols, rows: rows, branches: 0, tab_row: 1, rule_row: 2, pane_top: 3,
                     pane_height: rows - 4, pane_left: 1, pane_width: cols - 2, status_row: rows - 1)
      end

      # Both main rails share this length, so the top-left and bottom-right clusters mirror at every width
      def main_rail(cols)
        cols * 11 / 20
      end

      def trunk_length(rows)
        rows * 2 / 5
      end
    end
  end
end
