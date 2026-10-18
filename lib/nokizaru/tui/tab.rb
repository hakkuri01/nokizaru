# frozen_string_literal: true

module Nokizaru
  module TUI
    # One module's stream of classic output lines, wrapped for the pane width and scrolled independently
    class Tab
      MAX_LINES = 20_000

      attr_reader :key, :label, :lines, :dropped
      attr_accessor :state

      def initialize(key, label)
        @key = key
        @label = label
        @state = :pending
        @lines = []
        @dropped = 0
        @width = nil
        @rows = []
        @counts = []
        @offset = 0
        @tail = true
      end

      # O(1) amortized: only the new line is wrapped while the cache matches the pane width
      def append(line)
        @lines << line
        if @width
          wrapped = TerminalText.wrap(line, @width)
          @rows.concat(wrapped)
          @counts << wrapped.length
        end
        drop_oldest if @lines.length > MAX_LINES
      end

      def rows(width)
        rewrap(width) unless @width == width
        @rows
      end

      def top(width, height)
        max_top = [rows(width).length - height, 0].max
        @tail ? max_top : @offset.clamp(0, max_top)
      end

      def scroll(delta, width, height)
        max_top = [rows(width).length - height, 0].max
        @offset = (top(width, height) + delta).clamp(0, max_top)
        @tail = @offset >= max_top
      end

      def scroll_to_top
        @offset = 0
        @tail = false
      end

      def follow_tail
        @tail = true
      end

      private

      def rewrap(width)
        @width = width
        @rows = []
        @counts = []
        @lines.each do |line|
          wrapped = TerminalText.wrap(line, width)
          @rows.concat(wrapped)
          @counts << wrapped.length
        end
      end

      def drop_oldest
        @lines.shift
        @dropped += 1
        return unless @width

        removed = @counts.shift
        @rows.shift(removed)
        @offset = [@offset - removed, 0].max
      end
    end
  end
end
