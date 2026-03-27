# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumStatusColorTest < Minitest::Test
  def test_colorize_status_maps_2xx_to_green
    formatted = Nokizaru::Modules::DirectoryEnum.send(:colorize_status, 200)

    assert_equal "#{Nokizaru::UI::G}200#{Nokizaru::UI::W}", formatted
  end

  def test_colorize_status_maps_3xx_to_yellow
    formatted = Nokizaru::Modules::DirectoryEnum.send(:colorize_status, 302)

    assert_equal "#{Nokizaru::UI::Y}302#{Nokizaru::UI::W}", formatted
  end

  def test_colorize_status_maps_4xx_to_red
    formatted = Nokizaru::Modules::DirectoryEnum.send(:colorize_status, 404)

    assert_equal "#{Nokizaru::UI::R}404#{Nokizaru::UI::W}", formatted
  end

  def test_colorize_status_maps_5xx_to_magenta
    formatted = Nokizaru::Modules::DirectoryEnum.send(:colorize_status, 500)

    assert_equal "#{Nokizaru::UI::M}500#{Nokizaru::UI::W}", formatted
  end
end
