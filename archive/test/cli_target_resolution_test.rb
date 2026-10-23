# frozen_string_literal: true

require 'socket'
require 'tmpdir'
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

    output, = capture_io { info = runner.send(:parse_target, 'https://www.example.com') }

    assert_nil info[:ip]
    refute info[:type_ip]
    refute info[:private_ip]
    assert_equal 'www.example.com', info[:hostname]
    assert_equal 'example', info[:domain]
    assert_equal 'com', info[:suffix]
    assert_match(/stub resolver failure/, info[:ip_resolution_error])
    assert_includes output, 'unresolved (stub resolver failure)'
  end

  def test_parse_target_falls_back_to_last_label_suffix_when_public_suffix_rejects_domain
    runner = Nokizaru::CLI::Runner.new({ target: 'https://service.example.invalid' })
    info = nil
    runner.define_singleton_method(:resolve_hostname_ip) { |_hostname| '203.0.113.10' }

    PublicSuffix.stub(:parse, proc { raise ArgumentError, 'stub public suffix failure' }) do
      capture_io { info = runner.send(:parse_target, 'https://service.example.invalid') }
    end

    assert_equal 'service.example', info[:domain]
    assert_equal 'invalid', info[:suffix]
  end

  def test_ip_literal_targets_still_classify_private_addresses
    runner = Nokizaru::CLI::Runner.new({ target: 'http://192.168.1.10' })
    info = nil

    capture_io { info = runner.send(:parse_target, 'http://192.168.1.10') }

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

    output, = capture_io { runner.send(:run_portscan, { ps: true }, info, ctx) }

    result = ctx.run.fetch('modules').fetch('portscan')

    assert_equal 'skipped', result['status']
    assert_empty result['open_ports']
    assert_empty result['ports']
    assert_match(/stub resolver failure/, result['error'])
    assert_includes output, 'Skipping Port Scan'
  end

  def test_credentials_in_the_target_url_are_refused_before_anything_echoes_them
    target = 'https://user:secret@192.168.1.10'
    runner = Nokizaru::CLI::Runner.new({ target: target })
    error = nil

    output, = capture_io { error = assert_raises(SystemExit) { runner.send(:parse_target, target) } }

    assert_equal 1, error.status
    assert_includes output, 'Credentials in the target URL are not supported'
    refute_includes output, 'secret'
  end

  def test_third_party_lookups_get_the_target_without_its_query
    runner = Nokizaru::CLI::Runner.new({})

    assert_equal 'https://example.com/app', runner.send(:third_party_target, 'https://example.com/app?token=t#part')
  end

  def test_non_positive_timeouts_ports_and_thread_counts_stop_the_run
    { T: 0, pt: 0, dt: -1, sp: 0 }.each do |key, value|
      runner = Nokizaru::CLI::Runner.new({ key => value })

      output, = capture_io { assert_raises(SystemExit) { runner.send(:parse_runtime_options) } }

      assert_includes output, "-#{key} must be a positive number"
    end
    options = Nokizaru::CLI::Runner.new({ T: 7.5, pt: '20' }).send(:parse_runtime_options)

    assert_in_delta 7.5, options[:timeout]
    assert_equal 20, options[:pscan_threads]
  end

  def test_a_bad_export_option_stops_the_run_before_any_module_runs
    base = { target: 'http://192.168.1.10', headers: true, export: true }
    Dir.mktmpdir do |dir|
      blocker = File.join(dir, 'file')
      File.write(blocker, '')
      [{ o: 'txt,jsno' }, { cd: File.join(blocker, 'exports') }, { of: '../../keys', cd: dir }].each do |export|
        runner = Nokizaru::CLI::Runner.new(base.merge(export))

        output, = capture_io { assert_raises(SystemExit) { runner.plan! } }

        assert_includes output, 'Export failed', export.inspect
      end
    end
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
    runner = Nokizaru::CLI::Runner.new({ target: 'https://www.example.com' })
    runner.define_singleton_method(:resolve_hostname_ip) do |_hostname|
      raise SocketError, 'stub resolver failure'
    end
    runner
  end
end
