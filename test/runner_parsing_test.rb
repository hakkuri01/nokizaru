# frozen_string_literal: true

require_relative 'test_helper'

class RunnerParsingTest < Minitest::Test
  def test_runner_parses_repeatable_header_flags_from_raw_argv
    runner = Nokizaru::CLI::Runner.new(
      { header: 'X-Last: 2' },
      ['--url', 'https://example.com', '-H', 'Cookie: PHPSESSID=abc123', '--header', 'X-Role: admin']
    )

    headers = runner.send(:parsed_request_headers)

    assert_equal 'PHPSESSID=abc123', headers['Cookie']
    assert_equal 'admin', headers['X-Role']
  end

  def test_context_options_merges_request_headers_without_mutating_input
    original = { full: true }.freeze
    info = { request_headers: { 'Cookie' => 'PHPSESSID=abc123' } }
    runner = Nokizaru::CLI::Runner.new({}, [])

    merged = runner.send(:context_options, original, info)

    assert_equal true, original[:full]
    assert_equal 'PHPSESSID=abc123', merged[:request_headers]['Cookie']
  end
end
