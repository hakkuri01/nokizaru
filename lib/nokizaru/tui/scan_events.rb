# frozen_string_literal: true

module Nokizaru
  module TUI
    # How the dashboard follows the scan: the pulse, module states from the progress snapshot, follow focus,
    # and the run's end
    module ScanEvents
      PHASES = { 'running' => :running, 'done' => :done, 'failed' => :failed, 'skipped' => :skipped }.freeze

      private

      def on_tick(message)
        frame = ((message.now - @started_at) / Dashboard::PULSE_S).floor
        @dirty = true if running? && frame != @frame
        @frame = frame
        observe(message.snapshot, message.statuses) if running? && message.snapshot
      end

      def observe(snapshot, statuses)
        return if snapshot == @snapshot && statuses == @statuses

        @snapshot = snapshot
        @statuses = statuses.to_h
        snapshot[:modules].each { |key, state| @by_key[key]&.state = tab_state(key, state[:phase].to_s) }
        follow_target
        @dirty = true
      end

      # A module that finished but stored a skip (no API key) or a failure shows as such
      def tab_state(key, phase)
        state = PHASES.fetch(phase, :pending)
        return state unless state == :done

        status = @statuses[key].to_s
        return :skipped if status.start_with?('skipped')

        status == 'failed' ? :failed : :done
      end

      def follow_target
        return unless @follow

        target = running? ? @tabs.index { |tab| tab.key == @snapshot&.dig(:current_module) } : @tabs.length - 1
        @focus = target if target && (!running? || @tabs[target].state == :running)
      end

      def on_done(message)
        @outcome = message
        return finish(:done) if message.status.to_i.zero?

        @failure = "Scan stopped (exit #{message.status})"
        finish(:failed)
      end

      def on_failed(reason)
        @failure = reason
        finish(:failed)
      end

      def finish(phase)
        @phase = phase
        @tabs.each do |tab|
          tab.state = :skipped if tab.state == :pending
          tab.state = :failed if tab.state == :running && tab.key != :summary
        end
        @by_key[:summary].state = phase == :done ? :done : :failed
        follow_target
        @dirty = true
      end
    end
  end
end
