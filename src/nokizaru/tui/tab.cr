require "../terminal_text"

module Nokizaru
  module Tui
    # One module's stream of classic output lines, wrapped for the pane width and
    # scrolled independently. The wrap cache advances O(1) amortized per appended
    # line while the width is unchanged.
    class Tab
      MAX_LINES = 20_000

      enum State
        Pending
        Running
        Done
        Failed
        Skipped
      end

      getter key : String
      getter label : String
      getter lines : Array(String)
      getter dropped : Int32
      property state : State

      @width : Int32?

      def initialize(@key : String, @label : String)
        @state = State::Pending
        @lines = [] of String
        @dropped = 0
        @width = nil
        @rows = [] of String
        @counts = [] of Int32
        @offset = 0
        @tail = true
      end

      # O(1) amortized: only the new line is wrapped while the cache matches the
      # pane width.
      def append(line : String) : Nil
        @lines << line
        if width = @width
          wrapped = TerminalText.wrap(line, width)
          @rows.concat(wrapped)
          @counts << wrapped.size
        end
        drop_oldest if @lines.size > MAX_LINES
      end

      def rows(width : Int32) : Array(String)
        rewrap(width) unless @width == width
        @rows
      end

      def top(width : Int32, height : Int32) : Int32
        max_top = [rows(width).size - height, 0].max
        @tail ? max_top : @offset.clamp(0, max_top)
      end

      def scroll(delta : Int32, width : Int32, height : Int32) : Nil
        max_top = [rows(width).size - height, 0].max
        @offset = (top(width, height) + delta).clamp(0, max_top)
        @tail = @offset >= max_top
      end

      def scroll_to_top : Nil
        @offset = 0
        @tail = false
      end

      def follow_tail : Nil
        @tail = true
      end

      private def rewrap(width : Int32) : Nil
        @width = width
        @rows = [] of String
        @counts = [] of Int32
        @lines.each do |line|
          wrapped = TerminalText.wrap(line, width)
          @rows.concat(wrapped)
          @counts << wrapped.size
        end
      end

      private def drop_oldest : Nil
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
