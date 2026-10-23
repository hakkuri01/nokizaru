module Nokizaru
  module Tui
    # Where each part of a screen sits for a terminal size: the full HUD, a compact
    # fallback, or a too-small notice. A pure function of the terminal dimensions,
    # the number of top-cluster branches, and how many bottom readout rows the
    # screen hands up.
    module Layout
      extend self

      enum Mode
        Full
        Compact
        Tiny
      end

      record Geometry,
        mode : Mode,
        cols : Int32,
        rows : Int32,
        branches : Int32,
        tab_row : Int32?,
        rule_row : Int32?,
        pane_top : Int32,
        pane_height : Int32,
        pane_left : Int32,
        pane_width : Int32,
        status_row : Int32?

      FULL_MIN    = {80, 24}
      COMPACT_MIN = {50, 12}

      def measure(cols : Int32, rows : Int32, branches : Int32, footers : Int32 = 1) : Geometry
        return full(cols, rows, branches, footers) if cols >= FULL_MIN[0] && rows >= FULL_MIN[1]
        return compact(cols, rows) if cols >= COMPACT_MIN[0] && rows >= COMPACT_MIN[1]

        Geometry.new(mode: Mode::Tiny, cols: cols, rows: rows, branches: 0, tab_row: nil, rule_row: nil,
          pane_top: 0, pane_height: 0, pane_left: 0, pane_width: 0, status_row: nil)
      end

      # Both main rails share this length, so the top-left and bottom-right
      # clusters mirror at every width.
      def main_rail(cols : Int32) : Int32
        cols * 11 // 20
      end

      def trunk_length(rows : Int32) : Int32
        rows * 2 // 5
      end

      # Top cluster (head rail, identity, branches), a trunk row, tabs, rule, pane,
      # then the bottom cluster: one branch row per readout, the cheatsheet rail,
      # and the corner.
      private def full(cols : Int32, rows : Int32, branches : Int32, footers : Int32) : Geometry
        top_rows = 2 + branches
        pane_top = top_rows + 3
        status_row = rows - (footers + 2)
        Geometry.new(mode: Mode::Full, cols: cols, rows: rows, branches: branches, tab_row: top_rows + 1,
          rule_row: top_rows + 2, pane_top: pane_top, pane_height: status_row - pane_top,
          pane_left: 3, pane_width: cols - 6, status_row: status_row)
      end

      private def compact(cols : Int32, rows : Int32) : Geometry
        Geometry.new(mode: Mode::Compact, cols: cols, rows: rows, branches: 0, tab_row: 1, rule_row: 2,
          pane_top: 3, pane_height: rows - 4, pane_left: 1, pane_width: cols - 2, status_row: rows - 1)
      end
    end
  end
end
