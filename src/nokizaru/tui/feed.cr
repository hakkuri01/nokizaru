require "../terminal_text"
require "./messages"

module Nokizaru
  module Tui
    # The handoff from the scan fiber to the dashboard: lines tagged with their
    # module, plus scan-lifecycle events. Lines before the scan goes live (banner,
    # target resolution) are held aside, not streamed; the last error among them
    # surfaces if the run aborts in setup. A mutex guards the queue so the handoff
    # stays correct even under multi-threaded fiber scheduling.
    class Feed
      MAX_LINE_BYTES =   4096
      MAX_QUEUED     = 50_000
      MAX_PRELUDE    =     40

      alias Item = Messages::FeedLine | Messages::LifecycleEvent

      property tag : String?

      def initialize(@current_module : -> String?, @wake : (-> Nil)? = nil)
        @queue = Deque(Item).new
        @mutex = Mutex.new
        @live = false
        @tag = nil
        @prelude = [] of String
      end

      def live! : Nil
        @live = true
      end

      def live? : Bool
        @live
      end

      # Runs on the writing fiber, so the line belongs to the module running when
      # it was printed.
      def line(text : String) : Nil
        unless @live
          hold(text)
          return
        end

        queued = false
        @mutex.synchronize do
          # ponytail: a line past MAX_QUEUED is dropped unseen; the loop drains in
          # batches each tick, so only a stalled loop fills the queue, and exports
          # keep every result. Upgrade: a drop notice in Summary.
          if @queue.size < MAX_QUEUED
            @queue.push(Messages::FeedLine.new(@tag || @current_module.call, clean(text)))
            queued = true
          end
        end
        nudge if queued
      end

      def event(message : Messages::LifecycleEvent) : Nil
        @mutex.synchronize { @queue.push(message) }
        nudge
      end

      def drain(limit : Int32) : Array(Item)
        items = [] of Item
        @mutex.synchronize do
          while items.size < limit && !@queue.empty?
            items << @queue.shift
          end
        end
        items
      end

      # One actionable line from setup output, for an aborted run: the error-marked
      # line, else the last line printed.
      def prelude_error : String
        cleaned = @prelude.map { |line| TerminalText.strip_sgr(line).strip }.reject(&.empty?)
        marked = cleaned.rindex(&.includes?("⟦✘⟧"))
        (marked ? cleaned[marked] : nil) || cleaned.last? || "Scan could not start"
      end

      private def nudge : Nil
        @wake.try(&.call)
      end

      private def hold(text : String) : Nil
        @prelude << text
        while @prelude.size > MAX_PRELUDE
          @prelude.shift
        end
      end

      # Cap before sanitizing, so a hostile endless line costs at most one bounded pass.
      private def clean(text : String) : String
        capped = text.bytesize > MAX_LINE_BYTES
        safe = TerminalText.sanitize(capped ? text.byte_slice(0, MAX_LINE_BYTES) : text)
        capped ? "#{safe}#{TerminalText::RESET}#{TerminalText::ELLIPSIS}" : safe
      end
    end
  end
end
