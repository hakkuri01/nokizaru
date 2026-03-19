# frozen_string_literal: true

require_relative 'test_helper'

class ModuleRequestHeadersTest < Minitest::Test
  def test_headers_module_build_request_applies_custom_headers
    request = Nokizaru::Modules::Headers.send(
      :build_request,
      URI('https://example.com'),
      { 'Cookie' => 'PHPSESSID=abc123', 'X-Role' => 'admin' }
    )

    assert_equal 'PHPSESSID=abc123', request['Cookie']
    assert_equal 'admin', request['X-Role']
  end

  def test_target_intel_build_request_applies_custom_headers
    request = Nokizaru::TargetIntel::HTTPHelpers.send(
      :build_request,
      URI('https://example.com'),
      { 'X-Admin' => 'true' }
    )

    assert_equal 'true', request['X-Admin']
  end

  def test_crawler_build_request_applies_custom_headers
    request = Nokizaru::Modules::Crawler.send(
      :build_request,
      URI('https://example.com'),
      { 'Cookie' => 'role=admin' }
    )

    assert_equal 'role=admin', request['Cookie']
  end
end
