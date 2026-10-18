# frozen_string_literal: true

require_relative 'test_helper'

class TerminalTextTest < Minitest::Test
  T = Nokizaru::TerminalText

  def test_sanitize_keeps_sgr_color
    line = "\e[33m⟦!⟧\e[0m Server...⟦ \e[36mnginx\e[0m ⟧"

    assert_equal line, T.sanitize(line)
  end

  def test_sanitize_drops_non_sgr_escape_classes
    hostile = {
      'csi cursor move' => "a\e[2Ab",
      'csi erase' => "a\e[2Jb",
      'osc clipboard with bel' => "a\e]52;c;ZXZpbA==\ab",
      'osc title with st' => "a\e]0;owned\e\\b",
      'dcs' => "a\eP1$r0m\e\\b",
      'apc' => "a\e_payload\e\\b",
      'two byte escape' => "a\ecb",
      'charset escape' => "a\e(0b",
      'c0 bell and backspace' => "a\a\bb",
      'carriage return' => "a\rb",
      'del' => "a\x7Fb",
      'c1 csi' => "a\u009B2Jb",
      'c1 osc' => "a\u009D0;owned\u009Cb",
      'bidi override' => "a\u202Eb"
    }

    hostile.each { |name, text| assert_equal 'ab', T.sanitize(text), name }
  end

  def test_sanitize_drops_unterminated_osc_and_trailing_escape
    assert_equal 'a', T.sanitize("a\e]52;c;ZXZpbA")
    assert_equal 'a', T.sanitize("a\e")
  end

  def test_sanitize_expands_tabs_and_scrubs_invalid_utf8
    assert_equal 'a    b', T.sanitize("a\tb")
    assert_equal "a\uFFFDb", T.sanitize("a\xFFb".b)
    assert_equal 'é', T.sanitize('é'.encode(Encoding::ISO_8859_1))
  end

  def test_width_counts_cells
    assert_equal 5, T.width("\e[31mhello\e[0m")
    assert_equal 4, T.width('東京')
    assert_equal 5, T.width('⟦■⟧ ◈')
    assert_equal 2, T.width('🚀')
    assert_equal 1, T.width("e\u0301")
  end

  def test_wrap_hard_breaks_and_reopens_color
    rows = T.wrap("\e[36mabcdefgh\e[0m", 3)

    assert_equal ["\e[36mabc\e[0m", "\e[36mdef\e[0m", "\e[36mgh\e[0m"], rows
    assert(rows.all? { |row| T.width(row) <= 3 })
  end

  def test_wrap_never_splits_a_wide_character
    rows = T.wrap('a東京', 2)

    assert_equal %w[a 東 京], rows
  end

  def test_wrap_returns_short_lines_untouched
    assert_equal ['short'], T.wrap('short', 10)
    assert_equal [''], T.wrap('', 10)
  end

  def test_truncate_marks_the_cut
    assert_equal "abcd#{T::RESET}…", T.truncate('abcdefgh', 5)
    assert_equal 'abc', T.truncate('abc', 5)
    assert_equal '…', T.truncate('abcdefgh', 1), 'one cell holds only the mark, never the whole line'
  end

  def test_active_sgr_tracks_open_color
    assert_equal "\e[31m", T.active_sgr("\e[31mbanner line")
    assert_equal '', T.active_sgr("\e[31mred\e[0m plain")
  end
end
