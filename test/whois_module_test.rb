# frozen_string_literal: true

require_relative 'test_helper'

class WhoisModuleTest < Minitest::Test
  Whois = Nokizaru::Modules::WhoisLookup

  def test_parse_whois_lines_cleans_no_match_display_line
    pairs, misc = Whois.parse_whois_lines("No match for \"NONEXISTENT-EXAMPLE.COM\".\n")

    assert_empty pairs
    assert_equal ['No match for nonexistent-example.com'], misc
  end

  def test_raw_whois_disables_referrals_and_removes_registry_footer
    client = Minitest::Mock.new
    response = "Registry Domain: example.com\n>>> registry footer\nRegistrar Domain: example.com\n"
    client.expect(:lookup, response, ['example.com'])

    constructor = lambda do |**settings|
      assert_equal({ timeout: 10, referral: false }, settings)
      client
    end

    raw = ::Whois::Client.stub(:new, constructor) { Whois.raw_whois('example.com') }

    assert_equal "Registry Domain: example.com\n", raw
    client.verify
  end
end
