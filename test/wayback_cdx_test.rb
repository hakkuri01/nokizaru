# frozen_string_literal: true

require_relative 'test_helper'

class WaybackCDXTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body, :headers)
  HEADER = %w[timestamp original mimetype statuscode digest].freeze
  ROW = %w[20240102030405 https://example.com/admin text/html 200 digest].freeze

  def test_rejects_truncated_and_non_string_rows
    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([HEADER, ROW.first(2)])) }
    assert_raises(JSON::ParserError) do
      Wayback::CDX.parse_page(JSON.generate([HEADER, ROW.dup.tap { |row| row[4] = { 'bad' => true } }]))
    end
  end

  def test_rejects_duplicate_headers_and_malformed_resume_keys
    duplicate = %w[timestamp original mimetype statuscode timestamp]

    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([duplicate, ROW])) }
    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([HEADER, ROW, ['resume']])) }
    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([HEADER, ROW, []])) }
  end

  def test_rejects_overfull_pages_and_oversized_fields
    rows = Array.new(Wayback::CDX::PAGE_SIZE + 1, ROW)
    oversized = ROW.dup.tap { |row| row[2] = 'a' * 257 }

    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([HEADER, *rows])) }
    assert_raises(JSON::ParserError) { Wayback::CDX.parse_page(JSON.generate([HEADER, oversized])) }
  end

  def test_rejects_declared_oversized_response_before_parsing
    response = FakeResponse.new(200, '[]', { 'Content-Length' => (Wayback::CDX::MAX_BODY_BYTES + 1).to_s })

    Wayback::HTTP.stub(:get, response) do
      _, _, reason = Wayback::CDX.fetch_page({}, 1.0)

      assert_equal 'response_too_large', reason
    end
  end

  def test_normalizes_trailing_dot_in_provider_host_filter
    payload = Wayback::CDX.build_payload('https://example.com./')

    assert_equal 'example.com/', payload['url']
    assert_includes payload['filter'], 'example\\.com'
  end
end
