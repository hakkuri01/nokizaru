# frozen_string_literal: true

module Nokizaru
  # Shared transient status line for scan progress across modules
  class ProgressRail
    DEFAULT_INTERVAL_S = 0.12

    def initialize(enabled_modules:, io: $stdout, interval_s: DEFAULT_INTERVAL_S)
      @enabled_modules = Array(enabled_modules).map(&:to_sym)
      @io = io
      @interval_s = interval_s.to_f.positive? ? interval_s.to_f : DEFAULT_INTERVAL_S
      @mutex = Mutex.new
      @started_at = Time.now
      @frame_index = 0
      @running = false
      @rendered = false
      @snapshot = initial_snapshot
    end

    def start
      return self unless tty?

      @mutex.synchronize do
        @running = true
        @thread = Thread.new { ticker_loop }
      end
      self
    end

    def stop
      thread = nil
      @mutex.synchronize do
        @running = false
        thread = @thread
      end
      thread&.join(@interval_s * 2)
      @mutex.synchronize { clear_locked }
      self
    end

    def module_started(key, label: nil)
      update(key, phase: 'running', label: label || key.to_s, started_at: Time.now)
    end

    def module_finished(key)
      update(key, phase: 'done', finished_at: Time.now)
    end

    def module_failed(key, error: nil)
      update(key, phase: 'failed', error: error&.class&.name || error.to_s, finished_at: Time.now)
    end

    def update(key, fields = {})
      return unless tty?

      @mutex.synchronize do
        mod = key.to_sym
        @snapshot[:current_module] = mod
        @snapshot[:modules][mod] = @snapshot[:modules].fetch(mod, {}).merge(fields)
      end
    end

    def with_output(&block)
      return block.call unless tty?

      @mutex.synchronize do
        clear_locked
        begin
          block.call
        ensure
          render_locked if @running
        end
      end
    rescue Errno::EPIPE
      @mutex.synchronize { @running = false }
      nil
    end

    def active?
      tty? && @running
    end

    private

    def initial_snapshot
      {
        enabled_modules: @enabled_modules,
        current_module: @enabled_modules.first,
        started_at: @started_at,
        modules: @enabled_modules.to_h { |mod| [mod, { phase: 'pending', label: mod.to_s }] }
      }
    end

    def tty?
      @io.respond_to?(:tty?) && @io.tty?
    end

    def ticker_loop
      loop do
        sleep(@interval_s)
        @mutex.synchronize do
          break unless @running

          @frame_index += 1
          begin
            render_locked
          rescue Errno::EPIPE
            @running = false
            break
          end
        end
      end
    end

    def render_locked
      @io.print("\r\e[K#{UI.run_status_line(@snapshot, frame_index: @frame_index, tty: true)}")
      @io.flush
      @rendered = true
    end

    def clear_locked
      return unless @rendered

      @io.print("\r\e[K")
      @io.flush
      @rendered = false
    end
  end
end
