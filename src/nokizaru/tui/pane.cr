require "../ui"
require "../terminal_text"
require "./hud"
require "./tab"

module Nokizaru
  module Tui
    # The center of the dashboard: the module tab strip, its rule, and the focused
    # tab's results streaming down a vertical scaffold. The per-module header bar is
    # dropped (the tab names the module); instead a spine runs down the pane, solid
    # beside arrived lines and faint below. The visible window is sliced before
    # anything is prepended, so a frame never walks the tab's full history.
    module Pane
      extend self

      R         = UI::R
      G         = UI::G
      Y         = UI::Y
      W         = UI::W
      FAINT     = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED

      GLYPHS = {
        Tab::State::Pending => "#{FAINT}⟦·⟧", Tab::State::Running => "#{Y}⟦■⟧",
        Tab::State::Done => "#{G}⟦+⟧", Tab::State::Failed => "#{R}⟦✘⟧",
        Tab::State::Skipped => "#{Y}⟦!⟧",
      }
      SEPARATOR  = 2
      LEFT_MARK  = 2
      RIGHT_MARK = 3
      GUTTER     = 3

      def strip_row(dash, width : Int32) : String
        layout = strip(dash.tabs, dash.focus, width)
        String.build do |io|
          io << "#{FAINT}‹#{W} " if layout[:left]
          layout[:items].each_with_index do |item, position|
            io << " " * SEPARATOR if position > 0
            io << segment(dash, item[0])
          end
          io << "  #{FAINT}›#{W}" if layout[:right]
        end
      end

      # A faint rule with a node under the focused tab.
      def rule_row(dash, width : Int32) : String
        focused = strip(dash.tabs, dash.focus, width)[:items].find { |item| item[0] == dash.focus }
        start, size = focused ? {focused[1], focused[2]} : {0, 4}
        node = (start + 4 + ((size - 4) // 2)).clamp(0, width - 1)
        "#{FAINT_RED}#{"─" * node}#{W}#{R}◈#{W}#{FAINT_RED}#{"─" * (width - node - 1)}#{W}"
      end

      # The focused tab as a scaffold: a head node, then result lines down a spine,
      # faint below the last line.
      def body(dash, geo : Layout::Geometry) : Array(String)
        tab = dash.focused_tab
        result_width = [geo.pane_width - GUTTER, 1].max
        lines = tab.rows(result_width)
        lines = placeholder(tab) if lines.empty?
        height = [geo.pane_height - 1, 0].max
        window = visible(tab, lines, height, result_width)
        rows = ["#{R}◈#{W} #{R}#{tab.label}#{W}"]
        height.times { |index| rows << spine_row(window[index]?) }
        rows
      end

      # The window of tabs that fits, always holding the focused one; tabs are few,
      # so the scans stay tiny.
      private def strip(tabs, focus : Int32, width : Int32)
        widths = tabs.map { |tab| 4 + TerminalText.width(tab.label) }
        first = (0..focus).find { |start| fits?(widths, start, focus, width) } || focus
        col = first > 0 ? LEFT_MARK : 0
        items = [] of Tuple(Int32, Int32, Int32)
        (first...tabs.size).each do |index|
          reserve = index < tabs.size - 1 ? RIGHT_MARK : 0
          break if index > focus && col + widths[index] > width - reserve

          items << {index, col, widths[index]}
          col += widths[index] + SEPARATOR
        end
        {items: items, left: first > 0, right: items.last[0] < tabs.size - 1}
      end

      private def fits?(widths : Array(Int32), start : Int32, focus : Int32, width : Int32) : Bool
        used = widths[start..focus].sum + (SEPARATOR * (focus - start))
        used += LEFT_MARK if start > 0
        used += RIGHT_MARK if focus < widths.size - 1
        used <= width
      end

      private def segment(dash, index : Int32) : String
        tab = dash.tabs[index]
        color = if index == dash.focus
                  R
                elsif tab.state.pending?
                  FAINT
                else
                  ""
                end
        "#{GLYPHS[tab.state]}#{W} #{color}#{tab.label}#{W}"
      end

      # O(height): slice the window, then add the dropped-lines marker only when it
      # is actually at the top.
      private def visible(tab, lines : Array(String), height : Int32, width : Int32) : Array(String)
        top = tab.top(width, height)
        window = (lines[top, height]? || [] of String).dup
        if tab.dropped > 0 && top == 0
          window.unshift(drop_marker(tab))
          window.pop
        end
        window
      end

      private def spine_row(line : String?) : String
        return "#{FAINT_RED}╎#{W}" if line.nil?

        "#{R}│#{W}  #{line}"
      end

      private def placeholder(tab) : Array(String)
        case tab.state
        when .skipped? then ["#{Y}⟦!⟧#{W} Skipped"]
        when .pending? then ["#{FAINT}waiting…#{W}"]
        else                [""]
        end
      end

      private def drop_marker(tab) : String
        "#{Y}⟦!⟧#{W} #{tab.dropped} earlier lines dropped (exports keep everything)"
      end
    end
  end
end
