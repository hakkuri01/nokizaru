# frozen_string_literal: true

module Nokizaru
  module TUI
    # The handoff from scan threads to the dashboard: lines tagged with their module, plus scan lifecycle events.
    # Lines before the scan goes live (banner, target resolution) are held aside, not streamed; the last error
    # among them surfaces if the run aborts in setup
    class Feed
      MAX_LINE_BYTES = 4096
      MAX_QUEUED = 50_000
      MAX_PRELUDE = 40

      attr_writer :tag

      def initialize(runner, wake: nil)
        @runner = runner
        @wake = wake
        @queue = Thread::Queue.new
        @tag = nil
        @live = false
        @prelude = []
      end

      def live!
        @live = true
      end

      def live?
        @live
      end

      # Runs on the writing thread, so the line belongs to the module running when it was printed
      def line(_stream, text)
        return hold(text) unless @live
        # ponytail: a line past MAX_QUEUED is dropped unseen; the loop drains DRAIN_LIMIT lines per 0.05 s tick, so
        # only a stalled loop fills the queue, and exports keep every result. Upgrade: a drop notice in Summary
        return if @queue.size >= MAX_QUEUED

        @queue << [@tag || @runner.progress_rail&.current_module, clean(text)]
        nudge
      end

      def event(message)
        @queue << message
        nudge
      end

      def drain(limit)
        items = []
        while items.length < limit
          item = @queue.pop(timeout: 0)
          break if item.nil?

          items << item
        end
        items
      end

      # One actionable line from setup output, for an aborted run: the error-marked line, else the last line printed
      def prelude_error
        cleaned = @prelude.map { |line| TerminalText.strip_sgr(line).strip }.reject(&:empty?)
        marked = cleaned.rindex { |line| line.include?('⟦✘⟧') }
        (marked && cleaned[marked]) || cleaned.last || 'Scan could not start'
      end

      private

      # Nudges the UI loop so a line or event posted as the scan thread winds down is drained, not stranded
      def nudge
        @wake&.write_nonblock('.', exception: false)
      end

      def hold(text)
        @prelude << text
        @prelude.shift while @prelude.length > MAX_PRELUDE
        nil
      end

      # Cap before sanitizing, so a hostile endless line costs at most one bounded pass
      def clean(text)
        capped = text.bytesize > MAX_LINE_BYTES
        safe = TerminalText.sanitize(capped ? text.byteslice(0, MAX_LINE_BYTES) : text)
        capped ? "#{safe}#{TerminalText::RESET}#{TerminalText::ELLIPSIS}" : safe
      end
    end
  end
end
