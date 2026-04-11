# frozen_string_literal: true

require_relative 'test_helper'

class RunnerParsingTest < Minitest::Test
  def test_runner_parses_repeatable_header_flags_from_raw_argv
    runner = Nokizaru::CLI::Runner.new(
      { header: 'X-Last: 2' },
      ['--target', 'https://example.com', '-H', 'Cookie: PHPSESSID=abc123', '--header', 'X-Role: admin']
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

  def test_validated_target_requires_explicit_protocol
    runner = Nokizaru::CLI::Runner.new({ target: 'example.com' }, [])

    assert_raises(SystemExit) { runner.send(:validated_target!) }
  end

  def test_validated_target_accepts_http_and_https_with_matching_default_ports
    http_runner = Nokizaru::CLI::Runner.new({ target: 'http://127.0.0.1:80' }, [])
    https_runner = Nokizaru::CLI::Runner.new({ target: 'https://127.0.0.1:443' }, [])

    assert_equal 'http://127.0.0.1:80', http_runner.send(:validated_target!)
    assert_equal 'https://127.0.0.1:443', https_runner.send(:validated_target!)
  end

  def test_parse_target_accepts_ip_and_unusual_scheme_port_pairs
    runner = Nokizaru::CLI::Runner.new(
      {
        target: 'https://127.0.0.1:80',
        T: 10,
        sp: 443,
        pt: 50,
        dt: 30,
        d: '1.1.1.1'
      },
      []
    )

    info = runner.send(:parse_target, 'https://127.0.0.1:80')

    assert_equal 'https', info[:protocol]
    assert_equal '127.0.0.1', info[:hostname]
    assert_equal '127.0.0.1:80', info[:netloc]
    assert_equal true, info[:type_ip]
  end
end
