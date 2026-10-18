# frozen_string_literal: true

require_relative 'test_helper'

class TUIDecoderScreenTest < Minitest::Test
  TUI = Nokizaru::TUI

  def keys(bytes, decoder = TUI::Decoder.new)
    decoder.feed(bytes).map(&:name)
  end

  def test_decodes_every_dashboard_key
    input = "\t\e[Zlh\e[C\e[D1\e0jk\e[B\e[A\x04\x15\e[6~\e[5~gG\e[H\e[Ff\x03q"
    expected = %w[tab shift+tab l h right left 1 esc 0 j k down up ctrl+d ctrl+u pgdn pgup g G home end f ctrl+c q]

    assert_equal expected, keys(input)
  end

  def test_escape_before_a_key_in_one_read_is_its_own_key
    assert_equal %w[esc j], keys("\ej"), 'a fast Esc j in INSERT must leave INSERT, not type j'
    assert_equal %w[esc], keys("\e\e")
  end

  def test_decodes_ss3_and_modified_keys
    assert_equal %w[up down home end], keys("\eOA\eOB\eOH\eOF")
    assert_equal %w[up right], keys("\e[1;5A\e[1;2C")
  end

  def test_holds_a_sequence_split_across_reads
    decoder = TUI::Decoder.new

    assert_empty keys("\e[", decoder)
    assert_predicate decoder, :pending?
    assert_equal %w[pgdn], keys('6~', decoder)
    refute_predicate decoder, :pending?
  end

  def test_holds_a_split_utf8_character
    decoder = TUI::Decoder.new
    bytes = '東'.b

    assert_empty keys(bytes.byteslice(0, 2), decoder)
    assert_equal ['東'], keys(bytes.byteslice(2, 1), decoder)
  end

  def test_lone_escape_needs_a_flush
    decoder = TUI::Decoder.new

    assert_empty keys("\e", decoder)
    assert_equal %w[esc], decoder.flush.map(&:name)
    refute_predicate decoder, :pending?
  end

  def test_drops_an_overlong_unfinished_sequence
    decoder = TUI::Decoder.new

    assert_empty keys("\e[#{'1;' * 40}", decoder)
    refute_predicate decoder, :pending?
  end

  def test_screen_rewrites_only_changed_rows
    out = StringIO.new
    screen = TUI::Screen.new(out)

    screen.render(%w[alpha beta gamma])
    first = out.string.dup
    out.truncate(0)
    out.rewind
    screen.render(%w[alpha BETA gamma])

    assert first.start_with?("\e[?2026h")
    assert first.end_with?("\e[?2026l")
    assert_includes out.string, "\e[2;1H\e[2KBETA"
    refute_includes out.string, 'alpha'
    refute_includes out.string, 'gamma'
  end

  def test_screen_writes_nothing_for_an_unchanged_frame_and_repaints_after_invalidate
    out = StringIO.new
    screen = TUI::Screen.new(out)
    screen.render(%w[same])
    out.truncate(0)
    out.rewind

    screen.render(%w[same])

    assert_empty out.string

    screen.invalidate
    screen.render(%w[same])

    assert_includes out.string, 'same'
  end

  def test_screen_clears_rows_a_shorter_frame_leaves_behind
    out = StringIO.new
    screen = TUI::Screen.new(out)
    screen.render(%w[one two three])
    out.truncate(0)
    out.rewind

    screen.render(%w[one])

    assert_includes out.string, "\e[3;1H\e[2K"
  end
end
