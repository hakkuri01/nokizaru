# frozen_string_literal: true

module Nokizaru
  module TUI
    # Assembles a frame as row strings. The HUD clusters are shared chrome; each screen supplies a top profile,
    # a set of middle rows, and a bottom status line plus cheatsheet. O(rows x cols), never walking scan history
    module View
      module_function

      TOO_SMALL = "#{UI::Y}⟦!⟧#{UI::W} Terminal too small".freeze

      # Lays the top cluster, the middle region (framed by the trunks), and the bottom cluster into a full frame.
      # middle is a row-index to content hash for the pane region
      def compose(geo, top, middle, bottom)
        rows = Array.new(geo.rows, '')
        top.each_with_index { |row, index| rows[index] = row }
        (top.length...geo.status_row).each { |row| rows[row] = framed(geo, row, middle[row]) }
        bottom.each_with_index { |row, index| rows[geo.status_row + index] = row }
        rows
      end

      # Left trunk, the content, and the right trunk when one runs alongside this row
      def framed(geo, row, content)
        left = Hud.left_trunk(geo, row)
        right = Hud.right_trunk(geo, row)
        text = content.to_s
        return "#{left}  #{text}" if right.empty?

        "#{left}  #{text}#{' ' * [geo.pane_width - TerminalText.width(text), 0].max}  #{right}"
      end

      def tiny(cols, rows)
        frame = Array.new(rows, '')
        return frame if rows.zero?

        pad = ' ' * [(cols - TerminalText.width(TOO_SMALL)) / 2, 0].max
        frame[rows / 2] = TerminalText.truncate("#{pad}#{TOO_SMALL}", cols)
        frame
      end

      def dashboard(dash)
        geo = dash.geometry
        case geo.mode
        when :full then full(dash, geo)
        when :compact then compact(dash, geo)
        else tiny(geo.cols, geo.rows)
        end
      end

      def full(dash, geo)
        middle = { geo.tab_row => Pane.strip_row(dash, geo.pane_width),
                   geo.rule_row => Pane.rule_row(dash, geo.pane_width) }
        Pane.body(dash, geo).each_with_index { |line, index| middle[geo.pane_top + index] = line }
        compose(geo, Hud.top(dash.profile, geo, dash.cheats), middle,
                Hud.bottom(dash.status_text(geo.cols - 6), dash.cheats, geo))
      end

      def compact(dash, geo)
        middle = { geo.tab_row => Pane.strip_row(dash, geo.pane_width),
                   geo.rule_row => Pane.rule_row(dash, geo.pane_width) }
        Pane.body(dash, geo).each_with_index { |line, index| middle[geo.pane_top + index] = line }
        rows = [Hud.compact_top(dash.profile, geo.cols)]
        (1...geo.status_row).each { |row| rows << " #{middle[row]}" }
        rows << Hud.compact_status(dash.status_text(geo.cols - 2), geo.cols)
      end
    end
  end
end
