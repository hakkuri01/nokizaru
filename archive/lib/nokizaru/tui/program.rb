# frozen_string_literal: true

module Nokizaru
  module TUI
    # Input, signals, and command dispatch for the loop. Split from Program so the loop itself stays small
    module ProgramControl
      private

      def consume(ready)
        read_input if ready.include?(@terminal.input)
        read_signals if ready.include?(@terminal.wake)
        drain_wake if @wake && ready.include?(@wake)
      end

      def read_input
        bytes = @terminal.input.read_nonblock(Program::READ_BYTES, exception: false)
        return if bytes == :wait_readable
        return halt(nil) if bytes.nil?

        @input_at = now
        dispatch_all(@decoder.feed(bytes))
      end

      def read_signals
        @terminal.signals.each do |byte|
          case byte
          when 'w' then resize
          when 'i' then dispatch(Messages::Key.new(name: 'ctrl+c'))
          else halt(Program::SIGNAL_STATUS.fetch(byte, 143))
          end
        end
      end

      def drain_wake
        @wake.read_nonblock(4096, exception: false)
      end

      # The terminal went away or a termination signal arrived: stop the scan and leave the loop
      def halt(status)
        @signal_status = status
        @controller.stop_scan
        @quit = true
      end

      def resize
        cols, rows = @terminal.size
        @screen.invalidate
        dispatch(Messages::Resize.new(cols: cols, rows: rows))
      end

      def dispatch_all(messages)
        messages.each { |message| dispatch(message) }
      end

      def dispatch(message)
        @app.update(message).each { |command| run_command(command) }
      end

      def run_command(command)
        case command
        when :quit then halt(nil)
        when :run_scan then @controller.run_scan(@app)
        when :stop_and_form then stop_and_form
        end
      end

      def stop_and_form
        @controller.stop_scan
        @app.enter_form
      end
    end

    # The event loop. It waits only in IO.select, which releases the GVL, so scan threads keep full speed. Each
    # turn feeds input, signals, a tick (while something animates or a scan runs), and drained scan output to the
    # model as messages, then redraws when the model changed. Commands from the model go to the controller
    class Program
      include ProgramControl

      TICK_S = 0.05
      FRAME_S = 1.0 / 30
      ESCAPE_S = 0.03
      DRAIN_LIMIT = 2_000
      READ_BYTES = 4096
      SIGNAL_STATUS = { 't' => 143, 'h' => 129 }.freeze

      attr_reader :signal_status

      def initialize(app:, terminal:, controller:, clock:)
        @app = app
        @terminal = terminal
        @screen = Screen.new(terminal.output)
        @controller = controller
        @clock = clock
        @decoder = Decoder.new
        @quit = false
        @next_tick = 0.0
        @last_render = -FRAME_S
        @input_at = 0.0
      end

      def run
        @terminal.open
        @wake = @controller.wake
        @sources = [@terminal.input, @terminal.wake, @wake].compact
        resize
        render
        turn until @quit
      ensure
        @terminal.close
      end

      private

      def turn
        ready = Array(IO.select(@sources, nil, nil, timeout)&.first)
        consume(ready)
        dispatch_all(@decoder.flush) if @decoder.pending? && now - @input_at >= ESCAPE_S
        tick if (@wake && ready.include?(@wake)) || (ticking? && now >= @next_tick)
        render
      end

      def ticking?
        @app.animating? || @controller.scanning?
      end

      # Block until input when idle; wake for the next tick, escape timeout, or a pending throttled render
      def timeout
        return pending_render_wait if @app.dirty? && !ticking? && !@decoder.pending?
        return nil unless ticking? || @decoder.pending?

        wait = ticking? ? @next_tick - now : TICK_S
        wait = [wait, ESCAPE_S].min if @decoder.pending?
        wait = [wait, FRAME_S - (now - @last_render)].min if @app.dirty?
        wait.clamp(0.0, TICK_S)
      end

      def pending_render_wait
        [FRAME_S - (now - @last_render), 0.0].max
      end

      # A fresh snapshot first so late module states are current, then the scan output in order
      def tick
        @next_tick = now + TICK_S
        dispatch(observation)
        feed = @controller.feed
        return unless feed

        batch = []
        feed.drain(DRAIN_LIMIT).each do |item|
          next batch << item if item.is_a?(Array)

          flush_lines(batch)
          dispatch(observation)
          dispatch(item)
        end
        flush_lines(batch)
      end

      def flush_lines(batch)
        return if batch.empty?

        dispatch(Messages::Lines.new(items: batch.dup))
        batch.clear
      end

      def observation
        snapshot, statuses = @controller.observe
        Messages::Tick.new(now: now, snapshot: snapshot, statuses: statuses)
      end

      def render
        return unless @app.dirty? && now - @last_render >= FRAME_S

        @screen.render(@app.view)
        @app.clean!
        @last_render = now
      end

      def now
        @clock.call
      end
    end
  end
end
