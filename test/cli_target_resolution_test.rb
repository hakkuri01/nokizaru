# frozen_string_literal: true

require 'socket'
require_relative 'test_helper'

class CLITargetResolutionTest < Minitest::Test
  SETTINGS_IVARS = %i[
    @timeout @custom_dns @ssl_port @port_scan_threads @dir_enum_threads @dir_enum_redirect
    @dir_enum_verify_ssl @dir_enum_extension @dir_enum_wordlist
  ].freeze

  def setup
    @settings_snapshot = SETTINGS_IVARS.to_h do |ivar|
      [ivar, Nokizaru::Settings.instance_variable_get(ivar)]
    end
    apply_minimal_settings
  end

  def teardown
    @settings_snapshot.each do |ivar, value|
      Nokizaru::Settings.instance_variable_set(ivar, value)
    end
  end

  def test_parse_target_keeps_domain_parts_when_ip_resolution_fails
    runner = runner_with_resolution_failure
    info = nil

    output = capture_stdout { info = runner.send(:parse_target, 'https://lofree.com') }

    assert_nil info[:ip]
    refute info[:type_ip]
    refute info[:private_ip]
    assert_equal 'lofree.com', info[:hostname]
    assert_equal 'lofree', info[:domain]
    assert_equal 'com', info[:suffix]
    assert_match(/stub resolver failure/, info[:ip_resolution_error])
    assert_includes output, 'unresolved (stub resolver failure)'
  end

  def test_parse_target_falls_back_to_last_label_suffix_when_public_suffix_rejects_domain
    runner = Nokizaru::CLI::Runner.new({ target: 'https://httpbin.org' })
    info = nil
    runner.define_singleton_method(:resolve_hostname_ip) { |_hostname| '203.0.113.10' }

    capture_stdout { info = runner.send(:parse_target, 'https://httpbin.org') }

    assert_equal 'httpbin', info[:domain]
    assert_equal 'org', info[:suffix]
  end

  def test_ip_literal_targets_still_classify_private_addresses
    runner = Nokizaru::CLI::Runner.new({ target: 'http://192.168.1.10' })
    info = nil

    capture_stdout { info = runner.send(:parse_target, 'http://192.168.1.10') }

    assert_equal '192.168.1.10', info[:ip]
    assert info[:type_ip]
    assert info[:private_ip]
    assert_nil info[:ip_resolution_error]
  end

  def test_portscan_is_skipped_when_target_ip_is_unresolved
    runner = Nokizaru::CLI::Runner.new({ target: 'https://example.invalid' })
    ctx = Nokizaru::Context.new(run: { 'modules' => {} }, options: {})
    info = {
      ip: nil,
      ip_resolution_error: 'stub resolver failure',
      pscan_threads: 1,
      pscan_ports: nil,
      timeout: 1.0
    }

    output = capture_stdout { runner.send(:run_portscan, { ps: true }, info, ctx) }

    result = ctx.run.fetch('modules').fetch('portscan')
    assert_equal 'skipped', result['status']
    assert_empty result['open_ports']
    assert_empty result['ports']
    assert_match(/stub resolver failure/, result['error'])
    assert_includes output, 'Skipping Port Scan'
  end

  private

  def apply_minimal_settings
    Nokizaru::Settings.instance_variable_set(:@timeout, 1)
    Nokizaru::Settings.instance_variable_set(:@custom_dns, '1.1.1.1')
    Nokizaru::Settings.instance_variable_set(:@ssl_port, 443)
    Nokizaru::Settings.instance_variable_set(:@port_scan_threads, 1)
    Nokizaru::Settings.instance_variable_set(:@dir_enum_threads, 1)
    Nokizaru::Settings.instance_variable_set(:@dir_enum_redirect, false)
    Nokizaru::Settings.instance_variable_set(:@dir_enum_verify_ssl, false)
    Nokizaru::Settings.instance_variable_set(:@dir_enum_extension, '')
    Nokizaru::Settings.instance_variable_set(:@dir_enum_wordlist, '/tmp/unused')
  end

  def runner_with_resolution_failure
    runner = Nokizaru::CLI::Runner.new({ target: 'https://lofree.com' })
    runner.define_singleton_method(:resolve_hostname_ip) do |_hostname|
      raise SocketError, 'stub resolver failure'
    end
    runner
  end
end
