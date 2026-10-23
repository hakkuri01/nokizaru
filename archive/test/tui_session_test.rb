# frozen_string_literal: true

require_relative 'test_helper'
require 'pty'

class TUISessionTest < Minitest::Test
  TUI = Nokizaru::TUI
  ESCAPES = /\e\[[0-9;?<>]*[A-Za-z~]/

  # Stands in for the runner with the same phases and the kinds of output real modules produce
  class FakeRunner
    attr_reader :progress_rail

    def initialize(mode = :complete)
      @mode = mode
    end

    def boot!; end

    def plan!
      if @mode == :bad
        Nokizaru::UI.line(:error, 'Protocol Missing, Include http:// or https://')
        exit(1)
      end
      raise 'boom' if @mode == :raise

      @progress_rail = Nokizaru::ProgressRail.new(enabled_modules: %i[headers dns])
    end

    def tui_profile
      { target: 'https://example.com', ip: '127.0.0.1', modules: 'headers  dns', switches: 'none', notice: nil,
        modules_enabled: %i[headers dns] }
    end

    def module_statuses
      {}
    end

    def execute!
      @progress_rail.module_started(:headers, label: 'Headers')
      Nokizaru::UI.module_header('Headers')
      Nokizaru::UI.row(:info, 'Server', 'nginx')
      @progress_rail.module_finished(:headers)
      @progress_rail.module_started(:dns, label: 'DNS')
      Nokizaru::UI.row(:info, 'A-Record', '127.0.0.1')
      sleep 0.01 while @mode == :block
      @progress_rail.module_finished(:dns)
    end

    def finalize!
      Nokizaru::UI.row(:info, 'Completed in', '1.50s')
      [1.5, nil]
    end
  end

  def setup
    @master, @slave = PTY.open
    @slave.winsize = [32, 110]
    @output = +''
    @reader = Thread.new do
      loop { @output << @master.readpartial(65_536) }
    rescue IOError, Errno::EIO
      nil
    end
  end

  def teardown
    Nokizaru::InterruptState.reset!
    Nokizaru::UI.tui_mode = false
    [@master, @slave].each { |io| io.close unless io.closed? }
    @reader.join(1)
  end

  def test_full_flow_opens_form_runs_the_scan_then_q_returns_and_quits
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('Completed in 1.50s')
      @snap = screen_text
      @master.write('q')
      wait_for('Compose Scan')
      @master.write('q')
    end

    session.run
    driver.join

    assert_includes @output, TUI::Terminal::ENTER
    assert_terminal_restored
    assert_includes @snap, '◈ Summary'
    assert_includes @snap, 'Completed in'
    assert_equal '', after_leave.strip, 'results are not reprinted to the terminal on exit'
  end

  def test_results_stream_into_module_tabs_without_a_header_bar
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('Completed in 1.50s')
      @master.write('1')
      wait_for('◈ Headers')
      @snap = screen_text
      @master.write('qq')
    end

    session.run
    driver.join

    assert_includes @snap, '◈ Headers'
    assert_includes @snap, 'nginx'
    refute_match(/─{20,}\s+Headers/, @snap, 'no classic module header bar in the dashboard')
  end

  def test_bad_target_aborts_back_to_the_form
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('Protocol Missing')
      @snap = screen_text
      @master.write('q')
    end

    session(mode: :bad).run
    driver.join

    assert_includes @snap, 'Protocol Missing'
    refute_includes @output, 'Completed in'
  end

  def test_a_setup_error_returns_to_the_form_with_its_message_and_q_still_quits
    logged = []
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('boom')
      @snap = screen_text
      @master.write('q')
    end

    Nokizaru::Log.stub(:write, ->(message) { logged << message }) { session(mode: :raise).run }
    driver.join

    assert_includes @snap, 'Unexpected error: RuntimeError: boom'
    assert(logged.any? { |line| line.start_with?('[tui] Scan failed: RuntimeError: boom') && line.include?(__FILE__) },
           'the runtime log keeps where the error was raised')
  end

  def test_the_runner_gets_the_invocation_flags_the_form_has_no_field_for
    argv = ['--full', '--no-dir', '--target', 'https://example.com', '-H', 'Cookie: hunter2']
    received = nil
    factory = lambda do |_opts, args|
      received = args
      FakeRunner.new(:complete)
    end
    driver = drive do
      wait_for('-H ×1')
      @snap = screen_text
      @master.write("\r")
      wait_for('Completed in 1.50s')
      @master.write('qq')
    end

    TUI::Session.new(options: { target: 'https://example.com', full: true, nb: true }, argv: argv, input: @slave,
                     output: @slave, runner_factory: factory).run
    driver.join

    assert_equal argv, received
    assert_includes @snap, '--no-dir'
    refute_includes @snap, 'hunter2'
  end

  def test_q_stops_a_running_scan_and_returns_to_the_form
    baseline = Thread.list
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('A-Record')
      @master.write('q')
      wait_for('Compose Scan')
      @master.write('q')
    end

    session(mode: :block).run
    driver.join

    assert_empty (Thread.list - baseline).select(&:alive?)
  end

  def test_sigterm_restores_the_terminal_and_exits
    driver = drive do
      wait_for('Compose Scan')
      @master.write("\r")
      wait_for('A-Record')
      Process.kill('TERM', Process.pid)
    end

    error = assert_raises(SystemExit) { session(mode: :block).run }
    driver.join

    assert_equal 143, error.status
    assert_terminal_restored
  end

  private

  def session(mode: :complete, options: { target: 'https://example.com', full: true, nb: true })
    TUI::Session.new(options: options, input: @slave, output: @slave,
                     runner_factory: ->(_opts, _argv) { FakeRunner.new(mode) })
  end

  # The live screen rebuilt from the row-addressed writes (last write per row wins), not the cumulative stream
  def screen_text
    rows = {}
    @output.dup.force_encoding(Encoding::UTF_8).scrub
           .scan(/\e\[(\d+);1H\e\[2K(.*?)(?=\e\[\d+;1H|\e\[\?2026l|\z)/m) do |row, text|
      rows[row.to_i] = text.gsub(ESCAPES, '')
    end
    rows.keys.sort.map { |row| rows[row] }.join("\n")
  end

  def after_leave
    wait_output(TUI::Terminal::LEAVE)
    @output.dup.force_encoding(Encoding::UTF_8).scrub.split(TUI::Terminal::LEAVE, 2).last.to_s.gsub(ESCAPES, '')
  end

  def assert_terminal_restored
    wait_output(TUI::Terminal::LEAVE)

    assert_includes @output, TUI::Terminal::LEAVE
  end

  # Waits for the reader thread to capture a sequence the UI just wrote (the alt-screen teardown races the assert)
  def wait_output(text, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until @output.include?(text)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def wait_for(text, timeout: 6)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until screen_text.include?(text)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        @master.write("\x03")

        flunk "timed out waiting for #{text.inspect}; last screen:\n#{screen_text[-800..]}"
      end
      sleep 0.01
    end
  end

  def drive(&)
    thread = Thread.new(&)
    thread.report_on_exception = false
    thread
  end
end
