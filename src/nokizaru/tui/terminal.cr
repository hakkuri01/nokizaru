module Nokizaru
  module Tui
    # The winsize ioctl, which Crystal's stdlib does not expose. The request
    # constant differs by platform.
    @[Link("c")]
    lib LibTermSize
      # ws_row, ws_col, ws_xpixel, ws_ypixel as one array keeps the C layout
      # without unused per-field accessors; only row (0) and col (1) are read.
      struct Winsize
        cells : UInt16[4]
      end

      # `ioctl` is variadic in C (`int ioctl(int, unsigned long, ...)`) and MUST
      # be declared variadic so the winsize pointer travels by the C variadic
      # convention. On Apple silicon the fixed and variadic arguments use
      # different registers, so a fixed third parameter is read from the wrong
      # place and the struct is never filled, leaving the size at the 80x24
      # fallback (the "TUI launches tiny and never rescales" bug).
      fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
    end

    # Owns the real terminal for a session: raw input, the alternate screen, and the
    # window size. It does not grab the mouse (no button reporting), so the
    # terminal's own selection and copy keep working; the alternate-scroll mode lets
    # the wheel scroll the pane as arrow keys without that grab. Signals and the
    # event loop live in Program; this type is just the terminal's state, so it is
    # testable over a pipe.
    class Terminal
      # Alternate screen, hidden cursor, no autowrap (a mismeasured row clips
      # instead of breaking the frame), alternate-scroll so the wheel moves the
      # pane, then a clear.
      ENTER = "\e[?1049h\e[?25l\e[?7l\e[?1007h\e[2J"
      LEAVE = "\e[?1007l\e[?7h\e[?25h\e[?1049l"

      {% if flag?(:darwin) %}
        TIOCGWINSZ = 0x40087468_u64
      {% else %}
        TIOCGWINSZ = 0x5413_u64
      {% end %}

      getter input : IO::FileDescriptor
      getter output : IO::FileDescriptor

      @saved : LibC::Termios?

      def initialize(@input : IO::FileDescriptor = STDIN, @output : IO::FileDescriptor = STDOUT)
        @saved = nil
        @raw = false
        @opened = false
      end

      def open : Nil
        enter_raw if @input.tty?
        @output.print(ENTER)
        @output.flush
        @opened = true
      end

      def close : Nil
        return unless @opened

        @output.print(LEAVE)
        @output.flush
        restore_raw
        @opened = false
      end

      def size : Tuple(Int32, Int32)
        ws = LibTermSize::Winsize.new
        result = LibTermSize.ioctl(@output.fd, TIOCGWINSZ, pointerof(ws))
        rows = ws.cells[0].to_i
        cols = ws.cells[1].to_i
        return {80, 24} if result != 0 || cols.zero? || rows.zero?

        {cols, rows}
      rescue
        {80, 24}
      end

      private def enter_raw : Nil
        termios = uninitialized LibC::Termios
        return unless LibC.tcgetattr(@input.fd, pointerof(termios)) == 0

        @saved = termios
        raw = termios
        LibC.cfmakeraw(pointerof(raw))
        LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(raw))
        @raw = true
      end

      private def restore_raw : Nil
        return unless @raw

        saved = @saved
        return unless saved

        termios = saved
        LibC.tcsetattr(@input.fd, LibC::TCSANOW, pointerof(termios))
        @raw = false
      end
    end
  end
end
