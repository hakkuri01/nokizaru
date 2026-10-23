require "./app"
require "./decoder"
require "./screen"
require "./terminal"
require "./messages"
require "./progress"
require "./feed"

module Nokizaru
  module Tui
    # The event loop, Crystal-native: a reader fiber turns terminal input into key
    # messages on a channel, signal traps push control events onto another, and the
    # controller's wake channel nudges the loop when scan output is ready. The loop
    # multiplexes these with a tick timeout via `select`, so it waits (not spins)
    # and the scan fibers run full speed while it is idle. Commands from the model
    # go to the controller, which is duck-typed (so the loop is testable with a
    # fake). This replaces Ruby's IO.select + self-pipe with fibers and channels.
    class Program(C)
      TICK_S       =   0.05
      ESCAPE_S     =   0.03
      IDLE_S       = 3600.0
      DRAIN_LIMIT  =  2_000
      READ_BYTES   =  4_096
      TERM_STATUS  =    143
      HUP_STATUS   =    129
      SIGNAL_BYTES = {Signal::WINCH => 'w', Signal::INT => 'i', Signal::TERM => 't', Signal::HUP => 'h'}

      getter signal_status : Int32?

      def initialize(@app : App, @terminal : Terminal, @controller : C, @clock : -> Float64)
        @decoder = Decoder.new
        @screen = Screen.new(@terminal.output)
        @keys = Channel(Messages::Key).new(1024)
        @control = Channel(Char).new(16)
        @quit = false
        @signal_status = nil
      end

      def run : Nil
        @terminal.open
        trap_signals
        spawn { reader_loop }
        resize
        render
        until @quit
          step
          render if @app.dirty?
        end
      ensure
        reset_signals
        @controller.stop_scan
        @terminal.close
      end

      private def step : Nil
        interval = (ticking? ? TICK_S : IDLE_S).seconds
        select
        when key = @keys.receive
          dispatch(key)
        when ctl = @control.receive
          control(ctl)
        when @controller.wake_channel.receive
          tick
        when timeout(interval)
          tick if ticking?
        end
      end

      private def ticking? : Bool
        @app.animating? || @controller.scanning?
      end

      private def control(ctl : Char) : Nil
        case ctl
        when 'w' then resize
        when 'i' then dispatch(Messages::Key.new("ctrl+c"))
        when 'q' then halt(nil)
        when 't' then halt(TERM_STATUS)
        when 'h' then halt(HUP_STATUS)
        end
      end

      private def dispatch(message : Messages::Message) : Nil
        @app.update(message).each { |command| run_command(command) }
      end

      private def run_command(command : App::Command) : Nil
        case command
        when .quit?     then halt(nil)
        when .run_scan? then @controller.run_scan(@app)
        when .stop_and_form?
          @controller.stop_scan
          @app.enter_form
        end
      end

      # The terminal went away or a termination signal arrived: stop the scan and
      # leave the loop.
      private def halt(status : Int32?) : Nil
        @signal_status = status
        @controller.stop_scan
        @quit = true
      end

      # A fresh snapshot first so late module states are current, then the scan
      # output in order.
      private def tick : Nil
        dispatch(observation)
        pump
      end

      private def observation : Messages::Tick
        snapshot, statuses = @controller.observe
        Messages::Tick.new(@clock.call, snapshot, statuses)
      end

      private def pump : Nil
        feed = @controller.feed
        return unless feed

        batch = [] of Messages::FeedLine
        feed.drain(DRAIN_LIMIT).each do |item|
          if item.is_a?(Messages::FeedLine)
            batch << item
          else
            flush_batch(batch)
            dispatch(observation)
            dispatch(item)
          end
        end
        flush_batch(batch)
      end

      private def flush_batch(batch : Array(Messages::FeedLine)) : Nil
        return if batch.empty?

        dispatch(Messages::Lines.new(batch.dup))
        batch.clear
      end

      private def resize : Nil
        cols, rows = @terminal.size
        @screen.invalidate
        dispatch(Messages::Resize.new(cols, rows))
      end

      private def render : Nil
        @screen.render(@app.view)
        @app.clean!
      end

      # A lone ESC is only known after a quiet gap, so the reader shortens its read
      # timeout while a sequence is pending and flushes on the gap.
      private def reader_loop : Nil
        buffer = Bytes.new(READ_BYTES)
        loop do
          @terminal.input.read_timeout = @decoder.pending? ? ESCAPE_S.seconds : nil
          read = read_chunk(buffer)
          next if read.nil?

          if read.zero?
            @control.send('q')
            break
          end
          @decoder.feed(buffer[0, read]).each { |key| @keys.send(key) }
        end
      rescue IO::Error
        @control.send('q')
      end

      private def read_chunk(buffer : Bytes) : Int32?
        @terminal.input.read(buffer)
      rescue IO::TimeoutError
        @decoder.flush.each { |key| @keys.send(key) }
        nil
      end

      private def trap_signals : Nil
        SIGNAL_BYTES.each do |signal, byte|
          signal.trap { @control.send(byte) }
        end
      end

      private def reset_signals : Nil
        SIGNAL_BYTES.each_key(&.reset)
      end
    end
  end
end
