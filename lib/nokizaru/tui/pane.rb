# frozen_string_literal: true

module Nokizaru
  module TUI
    # The center of the dashboard: the module tab strip, its rule, and the focused tab's results streaming down a
    # vertical scaffold. The per-module header bar is dropped (the tab names the module); instead a spine runs down
    # the pane, solid beside arrived lines and faint below, the header's underline turned vertical to catch results
    module Pane
      module_function

      R = UI::R
      G = UI::G
      Y = UI::Y
      W = UI::W
      FAINT = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED
      GLYPHS = { pending: "#{FAINT}⟦·⟧", running: "#{Y}⟦■⟧", done: "#{G}⟦+⟧", failed: "#{R}⟦✘⟧",
                 skipped: "#{Y}⟦!⟧" }.freeze
      SEPARATOR = 2
      LEFT_MARK = 2
      RIGHT_MARK = 3
      GUTTER = 3

      # The window of tabs that fits, always holding the focused one; tabs are few, so the scans stay tiny
      def strip(tabs, focus, width)
        widths = tabs.map { |tab| 4 + TerminalText.width(tab.label) }
        first = (0..focus).find { |start| fits?(widths, start, focus, width) } || focus
        col = first.positive? ? LEFT_MARK : 0
        items = []
        (first...tabs.length).each do |index|
          reserve = index < tabs.length - 1 ? RIGHT_MARK : 0
          break if index > focus && col + widths[index] > width - reserve

          items << [index, col, widths[index]]
          col += widths[index] + SEPARATOR
        end
        { items: items, left: first.positive?, right: items.last[0] < tabs.length - 1 }
      end

      def fits?(widths, start, focus, width)
        used = widths[start..focus].sum + (SEPARATOR * (focus - start))
        used += LEFT_MARK if start.positive?
        used += RIGHT_MARK if focus < widths.length - 1
        used <= width
      end

      def strip_row(dash, width)
        layout = strip(dash.tabs, dash.focus, width)
        row = +(layout[:left] ? "#{FAINT}‹#{W} " : '')
        layout[:items].each_with_index do |(index, _, _), position|
          row << (' ' * SEPARATOR) if position.positive?
          row << segment(dash, index)
        end
        row << "  #{FAINT}›#{W}" if layout[:right]
        row
      end

      def segment(dash, index)
        tab = dash.tabs[index]
        color = if index == dash.focus then R
                elsif tab.state == :pending then FAINT
                else ''
                end
        "#{GLYPHS.fetch(tab.state)}#{W} #{color}#{tab.label}#{W}"
      end

      # A faint rule with a node under the focused tab
      def rule_row(dash, width)
        _, start, size = strip(dash.tabs, dash.focus, width)[:items].find { |index, _, _| index == dash.focus }
        node = (start + 4 + ((size - 4) / 2)).clamp(0, width - 1)
        "#{FAINT_RED}#{'─' * node}#{W}#{R}◈#{W}#{FAINT_RED}#{'─' * (width - node - 1)}#{W}"
      end

      # The focused tab as a scaffold: a head node, then result lines down a spine, faint below the last line.
      # The visible window is sliced before anything is prepended, so a frame never walks the tab's full history
      def body(dash, geo)
        tab = dash.focused_tab
        result_width = [geo.pane_width - GUTTER, 1].max
        lines = tab.rows(result_width)
        lines = placeholder(tab) if lines.empty?
        height = [geo.pane_height - 1, 0].max
        window = visible(tab, lines, height, result_width)
        rows = ["#{R}◈#{W} #{R}#{tab.label}#{W}"]
        height.times { |index| rows << spine_row(window[index]) }
        rows
      end

      # O(height): slice the window, then add the dropped-lines marker only when it is actually at the top
      def visible(tab, lines, height, width)
        top = tab.top(width, height)
        window = (lines[top, height] || []).dup
        if tab.dropped.positive? && top.zero?
          window.unshift(drop_marker(tab))
          window.pop
        end
        window
      end

      def spine_row(line)
        return "#{FAINT_RED}╎#{W}" if line.nil?

        "#{R}│#{W}  #{line}"
      end

      def placeholder(tab)
        case tab.state
        when :skipped then ["#{Y}⟦!⟧#{W} Skipped"]
        when :pending then ["#{FAINT}waiting…#{W}"]
        else ['']
        end
      end

      def drop_marker(tab)
        "#{Y}⟦!⟧#{W} #{tab.dropped} earlier lines dropped (exports keep everything)"
      end
    end
  end
end
