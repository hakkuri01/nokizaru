# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumProgressTest < Minitest::Test
  def test_direnum_pulse_rail_ping_pongs_in_plain_mode
    frames = (0..8).map { |idx| Nokizaru::UI.direnum_pulse_rail(idx, tty: false) }

    assert_equal ['■······', '■■·····', '■■■····', '·■■■···', '··■■■··', '···■■■·', '····■■■', '·····■■', '····■■■'],
                 frames
  end

  def test_direnum_progress_line_uses_compact_single_space_shape
    line = Nokizaru::UI.direnum_progress(
      current: 421,
      total: 1200,
      elapsed_s: 8.8,
      frame_index: 1,
      stats: {
        success: 398,
        errors: 23,
        found: 17
      },
      tty: false
    )

    refute_includes line, "\r"
    assert_includes line, '421/1200'
    assert_match(%r{\d+\.\dr/s}, line)
    assert_includes line, 'ok 398'
    assert_includes line, 'err 23'
    assert_includes line, 'found 17'
    refute_match(/  +/, strip_ansi(line))
  end

  def test_print_progress_non_tty_emits_after_threshold
    runtime = progress_runtime(count: 49, success: 40, errors: 9, found: 5)
    scan = { total_urls: 120 }

    output, = capture_io do
      Nokizaru::Modules::DirectoryEnum.send(:print_progress, runtime, scan)
    end
    assert_equal '', output

    runtime[:count] = 50
    output, = capture_io do
      Nokizaru::Modules::DirectoryEnum.send(:print_progress, runtime, scan)
    end
    assert_includes output, '50/120'
  end

  def test_print_progress_force_emits_non_tty_line
    runtime = progress_runtime(count: 1, success: 1, errors: 0, found: 0)
    scan = { total_urls: 120 }

    output, = capture_io do
      Nokizaru::Modules::DirectoryEnum.send(:print_progress, runtime, scan, force: true)
    end

    assert_includes output, '1/120'
    refute_nil runtime[:progress_ui][:last_render_at]
  end

  def test_clear_progress_line_is_noop_for_non_tty
    output, = capture_io do
      Nokizaru::Modules::DirectoryEnum.send(:clear_progress_line)
    end

    assert_equal '', output
  end

  private

  def progress_runtime(count:, success:, errors:, found:)
    {
      progress_ui: {
        started_at_mono: nil,
        last_render_at: nil,
        last_plain_count: 0,
        ticker_active: false,
        ticker_stop: false,
        ticker_thread: nil
      },
      count: count,
      stats: {
        success: success,
        errors: errors
      },
      found: Array.new(found) { |idx| "hit-#{idx}" },
      start_time: Time.now - 10
    }
  end

  def strip_ansi(text)
    text.gsub(/\e\[[\d;]*m/, '')
  end
end
