# frozen_string_literal: true

require_relative 'test_helper'

class WhoisModuleTest < Minitest::Test
  Whois = Nokizaru::Modules::WhoisLookup

  def test_parse_whois_lines_cleans_no_match_display_line
    pairs, misc = Whois.parse_whois_lines("No match for \"NONEXISTENT-EXAMPLE.COM\".\n")

    assert_empty pairs
    assert_equal ['No match for nonexistent-example.com'], misc
  end
end
