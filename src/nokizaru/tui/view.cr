require "../ui"
require "../terminal_text"
require "./hud"
require "./pane"

module Nokizaru
  module Tui
    # Assembles a frame as row strings. The HUD clusters are shared chrome; each
    # screen supplies a top cluster, a set of middle rows, and a bottom cluster.
    # O(rows x cols), never walking scan history.
    module View
      extend self

      TOO_SMALL = "#{UI::Y}⟦!⟧#{UI::W} Terminal too small"

      # Lays the top cluster, the middle region (framed by the trunks), and the
      # bottom cluster into a full frame. middle maps a pane row index to its
      # content; a row with no entry frames to the trunks around empty space.
      def compose(geo : Layout::Geometry, top : Array(String), middle : Hash(Int32, String),
                  bottom : Array(String)) : Array(String)
        status_row = geo.status_row || geo.rows
        rows = Array.new(geo.rows, "")
        top.each_with_index { |row, index| rows[index] = row }
        (top.size...status_row).each { |row| rows[row] = framed(geo, row, middle[row]?) }
        bottom.each_with_index { |row, index| rows[status_row + index] = row }
        rows
      end

      def tiny(cols : Int32, rows : Int32) : Array(String)
        frame = Array.new(rows, "")
        return frame if rows.zero?

        pad = " " * [(cols - TerminalText.width(TOO_SMALL)) // 2, 0].max
        frame[rows // 2] = TerminalText.truncate("#{pad}#{TOO_SMALL}", cols)
        frame
      end

      # Left trunk, the content, and the right trunk when one runs alongside this row.
      private def framed(geo : Layout::Geometry, row : Int32, content : String?) : String
        left = Hud.left_trunk(geo, row)
        right = Hud.right_trunk(geo, row)
        text = content || ""
        return "#{left}  #{text}" if right.empty?

        "#{left}  #{text}#{" " * [geo.pane_width - TerminalText.width(text), 0].max}  #{right}"
      end

      # The dashboard frame: the tab strip, its rule, and the focused tab's results
      # on the scaffold, inside the HUD. dash is duck-typed (the Dashboard) so this
      # module need not depend on it.
      def dashboard(dash) : Array(String)
        geo = dash.geometry
        case geo.mode
        when .full?    then full(dash, geo)
        when .compact? then compact(dash, geo)
        else                tiny(geo.cols, geo.rows)
        end
      end

      private def full(dash, geo : Layout::Geometry) : Array(String)
        middle = pane_middle(dash, geo)
        compose(geo, Hud.top(dash.profile, geo, dash.cheats), middle,
          Hud.bottom([dash.status_text(geo.cols - 6)], dash.cheats, geo))
      end

      private def compact(dash, geo : Layout::Geometry) : Array(String)
        status_row = geo.status_row || geo.rows
        middle = pane_middle(dash, geo)
        rows = [Hud.compact_top(dash.profile, geo.cols)]
        (1...status_row).each { |row| rows << " #{middle[row]? || ""}" }
        rows << Hud.compact_status(dash.status_text(geo.cols - 2), geo.cols)
        rows
      end

      private def pane_middle(dash, geo : Layout::Geometry) : Hash(Int32, String)
        middle = {} of Int32 => String
        tab_row = geo.tab_row
        rule_row = geo.rule_row
        middle[tab_row] = Pane.strip_row(dash, geo.pane_width) if tab_row
        middle[rule_row] = Pane.rule_row(dash, geo.pane_width) if rule_row
        Pane.body(dash, geo).each_with_index { |line, index| middle[geo.pane_top + index] = line }
        middle
      end
    end
  end
end
