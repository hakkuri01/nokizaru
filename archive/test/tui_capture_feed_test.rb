# frozen_string_literal: true

require_relative 'test_helper'

class TUICaptureFeedTest < Minitest::Test
  TUI = Nokizaru::TUI
  M = Nokizaru::TUI::Messages

  FakeRail = Struct.new(:current_module)

  class FakeRunner
    attr_reader :progress_rail

    def initialize(current)
      @progress_rail = FakeRail.new(current)
    end

    def current=(value)
      @progress_rail.current_module = value
    end
  end

  def capture_lines
    lines = []
    capture = TUI::Capture.new(:out, ->(stream, line) { lines << [stream, line] })
    [capture, lines]
  end

  def live_feed(current = :headers)
    feed = TUI::Feed.new(FakeRunner.new(current))
    feed.live!
    feed
  end

  def test_whole_and_partial_writes_become_complete_lines
    capture, lines = capture_lines

    capture.puts('one')
    capture.print('tw', 'o')
    capture.write("\nthree\nfou")
    capture << "r\n"

    assert_equal %w[one two three four], lines.map(&:last)
  end

  def test_kernel_puts_and_warn_reach_the_capture_when_swapped
    out, lines = capture_lines
    err = TUI::Capture.new(:err, ->(stream, line) { lines << [stream, line] })
    with_streams(out, err) do
      Nokizaru::UI.row(:info, 'Label', 'value')
      puts 'direct'
      warn 'warned'
    end

    assert_equal %i[out out err], lines.map(&:first)
    assert_includes Nokizaru::TerminalText.strip_sgr(lines[0].last), 'Label...⟦ value ⟧'
    assert_equal %w[direct warned], lines.drop(1).map(&:last)
  end

  def test_partial_lines_are_kept_per_thread
    capture, lines = capture_lines

    capture.write('main-')
    Thread.new { capture.write("other\n") }.join
    capture.write("line\n")

    assert_equal %w[other main-line], lines.map(&:last)
  end

  def test_feed_holds_setup_output_until_it_goes_live
    feed = TUI::Feed.new(FakeRunner.new(:headers))

    feed.line(:out, "\e[31m⟦✘⟧ Protocol Missing\e[0m")
    feed.line(:err, 'noise')

    assert_empty feed.drain(10)
    assert_equal '⟦✘⟧ Protocol Missing', feed.prelude_error

    feed.live!
    feed.line(:out, 'now streaming')

    assert_equal [[:headers, 'now streaming']], feed.drain(10)
  end

  def test_feed_tags_lines_with_the_running_module_at_write_time
    runner = FakeRunner.new(:headers)
    feed = TUI::Feed.new(runner)
    feed.live!

    feed.line(:out, 'from headers')
    runner.current = :dns
    feed.line(:out, 'from dns')
    feed.tag = :summary
    feed.line(:out, 'findings')

    assert_equal [[:headers, 'from headers'], [:dns, 'from dns'], [:summary, 'findings']], feed.drain(10)
  end

  def test_feed_sanitizes_and_caps_lines
    feed = live_feed(:dir)

    feed.line(:out, "safe\e]52;c;ZXZpbA==\a\e[36m ok\e[0m")
    feed.line(:out, 'y' * (TUI::Feed::MAX_LINE_BYTES * 3))
    (_, clean), (_, capped) = feed.drain(10)

    assert_equal "safe\e[36m ok\e[0m", clean
    assert_operator capped.bytesize, :<=, TUI::Feed::MAX_LINE_BYTES + 8
    assert capped.end_with?('…')
  end

  def test_feed_drain_is_bounded_and_keeps_order_with_events
    feed = live_feed(:ps)
    5.times { |index| feed.line(:out, "line #{index}") }
    done = M::ScanDone.new(elapsed: 1.0, export_dir: nil, status: 0)
    feed.event(done)

    assert_equal 3, feed.drain(3).length
    assert_equal [[:ps, 'line 3'], [:ps, 'line 4'], done], feed.drain(10)
    assert_empty feed.drain(10)
  end

  def test_feed_drops_lines_beyond_the_queue_cap
    feed = live_feed(:dir)
    stub_const(TUI::Feed, :MAX_QUEUED, 2) { 3.times { feed.line(:out, 'x') } }

    assert_equal 2, feed.drain(10).length
  end

  def test_progress_updates_do_no_io_when_the_rail_never_starts
    io = Class.new(StringIO) { def tty? = true }.new
    rail = Nokizaru::ProgressRail.new(enabled_modules: %i[dir], io: io)

    10_000.times { |count| rail.update(:dir, current: count, total: 10_000) }

    assert_empty io.string
    assert_equal 9_999, rail.snapshot.dig(:modules, :dir, :current)
  end

  private

  def with_streams(out, err)
    saved = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    yield
  ensure
    $stdout, $stderr = saved
  end

  def stub_const(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end
end
