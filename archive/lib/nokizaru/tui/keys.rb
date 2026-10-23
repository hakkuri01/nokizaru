# frozen_string_literal: true

module Nokizaru
  module TUI
    # Tab and scroll navigation for the dashboard. q and Ctrl+C are handled one level up by the app.
    # The wheel arrives as arrow keys (the terminal's alternate-scroll mode), so there is no mouse handling here
    module DashboardNav
      NEXT = %w[tab l right].freeze
      PREVIOUS = %w[shift+tab h left].freeze
      LINES = { 'j' => 1, 'down' => 1, 'k' => -1, 'up' => -1 }.freeze

      private

      def on_key(name)
        navigate(name)
        @dirty = true
      end

      def navigate(name)
        if NEXT.include?(name) then cycle(1)
        elsif PREVIOUS.include?(name) then cycle(-1)
        elsif name.match?(/\A[0-9]\z/) then jump(name == '0' ? 9 : name.to_i - 1)
        elsif LINES.key?(name) then scroll(LINES[name])
        else page(name)
        end
      end

      def page(name)
        height = geometry.pane_height
        case name
        when 'ctrl+d' then scroll(height / 2)
        when 'ctrl+u' then scroll(-(height / 2))
        when 'pgdn' then scroll(height)
        when 'pgup' then scroll(-height)
        when 'g', 'home' then focused_tab.scroll_to_top
        when 'G', 'end' then focused_tab.follow_tail
        when 'f' then toggle_follow
        end
      end

      def cycle(delta)
        @focus = (@focus + delta) % @tabs.length
        @follow = false
      end

      def jump(index)
        return unless index < @tabs.length

        @focus = index
        @follow = false
      end

      # The pane reserves a head row and a spine gutter, so results scroll in the rows below the head
      def scroll(delta)
        geo = geometry
        focused_tab.scroll(delta, [geo.pane_width - Pane::GUTTER, 1].max, [geo.pane_height - 1, 0].max)
      end

      def toggle_follow
        @follow = !@follow
        follow_target if @follow
      end
    end
  end
end
