# frozen_string_literal: true

require_relative 'test_helper'

class RequestHeadersTest < Minitest::Test
  RequestHeaders = Nokizaru::RequestHeaders

  def test_parse_argv_accepts_short_long_and_assignment_forms
    headers = RequestHeaders.parse_argv([
                                          '-H', 'X-Test: one',
                                          '--header=Accept: application/json',
                                          '-H=User-Agent: custom'
                                        ])

    assert_equal 'one', headers['X-Test']
    assert_equal 'application/json', headers['Accept']
    assert_equal 'custom', headers['User-Agent']
  end

  def test_parse_header_rejects_empty_malformed_or_injection_values
    assert_raises(ArgumentError) { RequestHeaders.parse_header('') }
    error = assert_raises(ArgumentError) { RequestHeaders.parse_header('Authorization Bearer secret') }
    assert_raises(ArgumentError) { RequestHeaders.parse_header("X-Test: ok\r\nInjected: yes") }
    name_error = assert_raises(ArgumentError) { RequestHeaders.parse_header('Bad secret Header: value') }
    refute_includes error.message, 'secret'
    refute_includes name_error.message, 'secret'
  end

  def test_cli_values_rejects_missing_flag_value
    assert_raises(ArgumentError) { RequestHeaders.cli_values(['--header']) }
  end

  def test_summary_and_predicates_handle_non_hash_values
    assert RequestHeaders.any?('X-Test' => 'one')
    assert RequestHeaders.none?(nil)
    assert_equal '1 supplied', RequestHeaders.summary('X-Test' => 'one')
    assert_equal 'none', RequestHeaders.summary([])
  end
end
