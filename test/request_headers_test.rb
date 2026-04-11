# frozen_string_literal: true

require_relative 'test_helper'

class RequestHeadersTest < Minitest::Test
  def test_parse_argv_collects_repeatable_header_flags
    headers = Nokizaru::RequestHeaders.parse_argv([
                                                    '--target', 'https://example.com',
                                                    '-H', 'Cookie: PHPSESSID=abc123; uid=52',
                                                    '--header', 'X-Role: admin',
                                                    '--header=X-Trace: red'
                                                  ])

    assert_equal 'PHPSESSID=abc123; uid=52', headers['Cookie']
    assert_equal 'admin', headers['X-Role']
    assert_equal 'red', headers['X-Trace']
  end

  def test_parse_header_rejects_newlines
    error = assert_raises(ArgumentError) do
      Nokizaru::RequestHeaders.parse_header("Cookie: ok\r\nX-Evil: 1")
    end

    assert_includes error.message, 'CR/LF'
  end

  def test_parse_header_requires_name_value_format
    error = assert_raises(ArgumentError) do
      Nokizaru::RequestHeaders.parse_header('invalid-header')
    end

    assert_includes error.message, "expected 'Name: Value'"
  end
end
