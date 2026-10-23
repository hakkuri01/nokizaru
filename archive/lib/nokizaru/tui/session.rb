# frozen_string_literal: true

module Nokizaru
  module TUI
    # The interactive controller: it owns the terminal and the scan lifecycle while the program loop drives the
    # model. A scan starts on a form submit and can be stopped and re-run; module output is captured into the
    # feed. Nothing is printed on exit: the alternate screen is left clean and exports are the only results kept
    class Session
      STOP_GRACE_S = 2.0
      CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      def initialize(options:, argv: [], input: $stdin, output: $stdout, clock: CLOCK,
                     runner_factory: ->(opts, args) { Nokizaru::CLI::Runner.new(opts, args) })
        @options = options.respond_to?(:to_h) ? options.to_h.transform_keys(&:to_sym) : {}
        @argv = argv
        @input = input
        @output = output
        @clock = clock
        @runner_factory = runner_factory
      end

      def run
        @real_streams = [$stdout, $stderr]
        @wake_r, @wake_w = IO.pipe
        UI.tui_mode = true
        form = Form.new(prefill: @options, argv: @argv)
        @app = App.new(form: form, banner: banner_lines, now: @clock.call, opening: !@options[:nb])
        program = Program.new(app: @app, terminal: Terminal.new(input: @input, output: @output),
                              controller: self, clock: @clock)
        program.run
        exit(program.signal_status) if program.signal_status
      ensure
        stop_scan
        UI.tui_mode = false
        [@wake_r, @wake_w].each { |io| io&.close unless io&.closed? }
      end

      # The pipe the feed nudges when a line or event is posted, so the loop wakes to drain it
      def wake
        @wake_r
      end

      # Builds a Runner from the form's options and runs its whole lifecycle on a background thread, streaming
      # module output into the feed. Setup output (banner, target resolution) is held until the scan goes live
      def run_scan(app)
        request = app.scan_request
        @runner = @runner_factory.call(request[:options], request[:argv])
        @feed = Feed.new(@runner, wake: @wake_w)
        InterruptState.reset!
        swap_streams
        @baseline = Thread.list
        @scan = Thread.new { scan_body }
      end

      # Stops a running scan the way the classic interrupt does, minus the threads that predate it, and restores
      # the real streams so the next run (or exit) starts clean
      def stop_scan
        return unless @scan

        InterruptState.interrupt!
        (Thread.list - @baseline).each(&:kill) if @baseline
        @scan.join(STOP_GRACE_S)
        @scan = @feed = @runner = nil
        $stdout, $stderr = @real_streams
      end

      def observe
        return [nil, {}] unless @runner && @feed&.live?

        [@runner.progress_rail.snapshot, @runner.module_statuses]
      end

      attr_reader :feed

      def scanning?
        @scan&.alive? || false
      end

      private

      def scan_body
        Thread.current.report_on_exception = false
        @runner.boot!
        @runner.plan!
        @feed.event(Messages::ScanStarted.new(profile: @runner.tui_profile))
        @feed.live!
        @runner.execute!
        @feed.tag = :summary
        elapsed, export_dir = @runner.finalize!
        @feed.event(Messages::ScanDone.new(elapsed: elapsed, export_dir: export_dir, status: 0))
      rescue SystemExit => e
        finish_abort(e)
      rescue StandardError => e
        report_failure(e)
      end

      # The screen gets the class and message; the runtime log also keeps where it was raised, for a bug report
      def report_failure(error)
        trace = Array(error.backtrace).first(10).join(' | ')
        Log.write("[tui] Scan failed: #{error.class}: #{error.message} | #{trace}")
        @feed.event(Messages::ScanFailed.new(reason: "Unexpected error: #{error.class}: #{error.message}"))
      end

      def finish_abort(error)
        if @feed.live?
          @feed.event(Messages::ScanDone.new(elapsed: nil, export_dir: nil, status: error.status))
        else
          @feed.event(Messages::ScanAborted.new(reason: @feed.prelude_error))
        end
      end

      def swap_streams
        feed = @feed
        $stdout = Capture.new(:out, ->(stream, line) { feed.line(stream, line) })
        $stderr = Capture.new(:err, ->(stream, line) { feed.line(stream, line) })
      end

      def banner_lines
        lines = Banner::TEXT.split("\n")
        blank = ->(line) { line.strip.empty? }
        lines.drop_while(&blank).reverse.drop_while(&blank).reverse
      end
    end
  end
end
