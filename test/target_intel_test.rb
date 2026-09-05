# frozen_string_literal: true

require_relative 'test_helper'

class TargetIntelTest < Minitest::Test
  Response = Struct.new(:headers)

  def test_same_scope_canonical_host_redirect_reanchors_and_preserves_path
    target = 'https://example.com/search?q=test'
    profile = Nokizaru::TargetIntel.profile(
      target,
      response: Response.new({ 'location' => 'https://www.example.com/' })
    )

    decision = Nokizaru::TargetIntel.reanchor_decision(target, profile)

    assert decision[:reanchor]
    assert_equal 'https://www.example.com/search?q=test', decision[:effective_target]
    assert_equal 'same-scope', decision[:reason_code]
  end

  def test_same_host_and_https_downgrade_redirects_do_not_reanchor
    same_host = redirect_decision('https://example.com/app', '/login')
    downgrade = redirect_decision('https://example.com/app', 'http://www.example.com/login')

    refute same_host[:reanchor]
    refute downgrade[:reanchor]
  end

  def test_distinct_ip_addresses_are_not_same_scope
    refute Nokizaru::TargetIntel.same_scope_host?('127.0.0.1', '10.0.0.1')
    assert Nokizaru::TargetIntel.same_scope_host?('127.0.0.1', '127.0.0.1')
  end

  def test_cross_host_redirect_to_different_path_does_not_reanchor
    decision = redirect_decision('https://example.com/app', 'https://auth.example.com/login')

    refute decision[:reanchor]
    assert_equal 'https://example.com/app', decision[:effective_target]
  end

  private

  def redirect_decision(target, location)
    profile = Nokizaru::TargetIntel.profile(target, response: Response.new({ 'location' => location }))
    Nokizaru::TargetIntel.reanchor_decision(target, profile)
  end
end
