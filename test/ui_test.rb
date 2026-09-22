# frozen_string_literal: true

require_relative 'test_helper'

class UITest < Minitest::Test
  def test_module_header_uses_red_title_with_green_plus_marker
    io = StringIO.new

    Nokizaru::UI.module_header('Headers', io: io)

    output = io.string

    assert_includes output, "#{Nokizaru::UI::R}Headers#{Nokizaru::UI::W}"
    assert_includes output, Nokizaru::UI.prefix(:plus)
    refute_includes output, "#{Nokizaru::UI::C}Headers"
  end

  def test_banner_art_is_red
    runner = Object.new.extend(Nokizaru::CLI::Runner::Keys)

    output, = capture_io { runner.send(:banner) }

    assert_includes output, Nokizaru::UI::R.to_s
    refute Nokizaru::CLI.const_defined?(:G, false)
  end
end
