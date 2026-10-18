# frozen_string_literal: true

require 'io/console'

module Nokizaru
  module TUI
    # Owns the real terminal for a session: raw input, the alternate screen, and signal wakeups. It does not grab
    # the mouse (no button reporting), so the terminal's own selection and copy keep working, matching Jekyll //
    # Hyde; the alternate-scroll mode lets the wheel scroll the pane as arrow keys without that grab
    class Terminal
      # Alternate screen, hidden cursor, no autowrap (a mismeasured row clips instead of breaking the frame),
      # alternate-scroll so the wheel moves the pane, then a clear
      ENTER = "\e[?1049h\e[?25l\e[?7l\e[?1007h\e[2J"
      LEAVE = "\e[?1007l\e[?7h\e[?25h\e[?1049l"
      SIGNALS = { 'WINCH' => 'w', 'TERM' => 't', 'HUP' => 'h', 'INT' => 'i' }.freeze

      attr_reader :input, :output, :wake

      def initialize(input:, output:)
        @input = input
        @output = output
      end

      def open
        @mode = @input.console_mode
        @input.raw!
        @wake, @waker = IO.pipe
        @previous = SIGNALS.to_h { |name, byte| [name, Signal.trap(name) { notify(byte) }] }
        @output.write(ENTER)
        self
      end

      def close
        return unless @wake

        @output.write(LEAVE)
        @previous.each { |name, handler| Signal.trap(name, handler || 'DEFAULT') }
        @input.console_mode = @mode
        [@wake, @waker].each(&:close)
        @wake = nil
      end

      def size
        rows, cols = @output.winsize
        [cols, rows]
      rescue IOError, SystemCallError, NoMethodError
        [80, 24]
      end

      def signals
        bytes = @wake.read_nonblock(64, exception: false)
        bytes.is_a?(String) ? bytes.chars : []
      end

      private

      # Trap context forbids locks, so a signal only writes one byte and the loop does the work
      def notify(byte)
        @waker.write_nonblock(byte, exception: false)
      end
    end
  end
end
