# frozen_string_literal: true

require_relative 'test_helper'

class HTTPClientHelpersTest < Minitest::Test
  Response = Struct.new(:status, :body, :headers, keyword_init: true)

  def test_request_headers_merge_defaults_and_override_user_agent
    headers = Nokizaru::HTTPClient.request_headers(base: { 'Accept' => 'application/json' }, user_agent: 'custom')

    assert_equal 'custom', headers['User-Agent']
    assert_equal 'application/json', headers['Accept']
    assert_equal 'gzip', headers['Accept-Encoding']
  end

  def test_response_helpers_handle_missing_or_malformed_values
    assert_equal 0, Nokizaru::HTTPClient.status_code(Object.new)
    assert_equal '', Nokizaru::HTTPClient.response_body(Object.new)
    assert_equal({}, Nokizaru::HTTPClient.response_headers(Object.new))
  end

  def test_header_value_handles_case_variants_and_arrays
    response = Response.new(headers: { 'content-type' => ['text/html', 'charset=utf-8'], 'X-Test' => 'one' })

    assert_equal 'text/html, charset=utf-8', Nokizaru::HTTPClient.header_value(response, 'Content-Type')
    assert_equal 'one', Nokizaru::HTTPClient.header_value(response, 'X-Test')
  end

  def test_each_response_header_downcases_and_joins_values
    response = Response.new(headers: { 'X-Test' => %w[one two] })
    yielded = []

    Nokizaru::HTTPClient.each_response_header(response) { |key, value| yielded << [key, value] }

    assert_equal [['x-test', 'one, two']], yielded
  end

  def test_status_predicates_use_normalized_status_code
    assert Nokizaru::HTTPClient.http_success?(Response.new(status: 204))
    refute Nokizaru::HTTPClient.http_success?(Response.new(status: 404))
    assert Nokizaru::HTTPClient.http_redirect?(Response.new(status: 302), [301, 302])
  end
end
