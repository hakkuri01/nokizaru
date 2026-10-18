# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'

class CLISettingsPathsTest < Minitest::Test
  SETTINGS_IVARS = %i[
    @timeout @custom_dns @ssl_port @port_scan_threads @dir_enum_threads @dir_enum_redirect
    @dir_enum_verify_ssl @dir_enum_extension @dir_enum_wordlist
  ].freeze

  def setup
    @settings_snapshot = SETTINGS_IVARS.to_h do |ivar|
      [ivar, Nokizaru::Settings.instance_variable_get(ivar)]
    end
  end

  def teardown
    @settings_snapshot.each do |ivar, value|
      Nokizaru::Settings.instance_variable_set(ivar, value)
    end
  end

  def test_cli_argv_normalizes_short_flags_and_assignment_forms
    argv = ['scan', '-nb', '-cd=/tmp/out', '-of', 'json']

    result = Nokizaru::CLIArgv.normalize_argv!(argv)

    assert_same argv, result
    assert_equal ['scan', '--nb', '--cd=/tmp/out', '--of', 'json'], argv
  end

  def test_paths_build_safe_target_export_directories
    assert_equal 'unknown', Nokizaru::Paths.send(:sanitize_domain_for_path, nil)
    assert_equal 'example.com', Nokizaru::Paths.send(:sanitize_domain_for_path, '..Example.COM..')
    assert_equal 'bad_path_name', Nokizaru::Paths.send(:sanitize_domain_for_path, 'bad/path:name')
    assert_equal 128, Nokizaru::Paths.send(:sanitize_domain_for_path, 'a' * 200).length

    Dir.mktmpdir do |dir|
      original_exports_dir = Nokizaru::Paths.instance_variable_get(:@exports_dir)
      Nokizaru::Paths.instance_variable_set(:@exports_dir, nil)

      Nokizaru::Paths.stub(:user_data_dir, dir) do
        assert_equal File.join(dir, 'exports', 'example.com'), Nokizaru::Paths.target_export_dir('Example.COM')
      end
    ensure
      Nokizaru::Paths.instance_variable_set(:@exports_dir, original_exports_dir)
    end
  end

  def test_keys_file_permissions_are_owner_only
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'keys.json')
      File.write(path, '{}')

      Nokizaru::Paths.stub(:keys_file, path) { Nokizaru::Paths.secure_keys_file! }

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_settings_assign_values_from_complete_config
    Nokizaru::Settings.assign_values(settings_config)

    assert_equal 12, Nokizaru::Settings.timeout
    assert_equal ['1.1.1.1'], Nokizaru::Settings.custom_dns
    assert_equal 443, Nokizaru::Settings.ssl_port
    assert_equal 20, Nokizaru::Settings.port_scan_threads
    assert_equal 10, Nokizaru::Settings.dir_enum_threads
    assert_equal false, Nokizaru::Settings.dir_enum_redirect
    assert_equal true, Nokizaru::Settings.dir_enum_verify_ssl
    assert_equal 'php,txt', Nokizaru::Settings.dir_enum_extension
    assert_match(%r{/wordlists/raft_med-dir_5k\.txt\z}, Nokizaru::Settings.dir_enum_wordlist)
  end

  def test_wordlist_option_resolves_curated_sizes_and_custom_paths
    assert_match(%r{/wordlists/raft_small-dir_2k\.txt\z}, Nokizaru::Settings.wordlist('small'))
    assert_match(%r{/wordlists/raft_med-dir_5k\.txt\z}, Nokizaru::Settings.wordlist('medium'))
    assert_match(%r{/wordlists/raft_big-dir_10k\.txt\z}, Nokizaru::Settings.wordlist('LARGE'))
    assert_equal '/tmp/custom.txt', Nokizaru::Settings.wordlist('/tmp/custom.txt')
  end

  def test_settings_config_sections_require_expected_keys
    assert_raises(KeyError) { Nokizaru::Settings.config_sections({}) }
  end

  def test_a_scan_never_rewrites_a_key_store_that_does_not_parse
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'keys.json')
      broken = %({ "shodan": "kept", })
      File.write(path, broken)

      Nokizaru::Paths.stub(:keys_file, path) do
        Nokizaru::Log.stub(:write, nil) { assert_nil Nokizaru::KeyStore.fetch('alienvault', env: 'NK_TEST_UNSET') }
      end

      assert_equal broken, File.read(path)
    end
  end

  def test_saving_a_key_refuses_a_store_that_does_not_parse_and_replaces_it_whole
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'keys.json')
      runner = Nokizaru::CLI::Runner.new({})
      with_key_store(path) do
        File.write(path, '{ "shodan": "kept", }')
        error = nil

        capture_io { error = assert_raises(SystemExit) { runner.send(:persist_key, 'virustotal', 'new') } }

        assert_equal 1, error.status
        assert_equal '{ "shodan": "kept", }', File.read(path)

        File.write(path, '{ "shodan": "kept" }')
        runner.send(:persist_key, 'virustotal', 'new')
      end

      assert_equal({ 'shodan' => 'kept', 'virustotal' => 'new' }, JSON.parse(File.read(path)))
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal ['keys.json'], Dir.children(dir), 'no temp file is left behind'
    end
  end

  def test_a_bare_key_name_reads_the_key_from_stdin_instead_of_argv
    runner = Nokizaru::CLI::Runner.new({})
    saved = nil
    runner.define_singleton_method(:persist_key) { |name, value| saved = [name, value] }
    stdin = $stdin
    $stdin = StringIO.new("ABC123\n")
    error = nil

    capture_io { error = assert_raises(SystemExit) { runner.send(:save_key, 'shodan') } }

    assert_equal 0, error.status
    assert_equal %w[shodan ABC123], saved
  ensure
    $stdin = stdin
  end

  private

  def with_key_store(path, &)
    Nokizaru::Paths.stub(:keys_file, path) do
      Nokizaru::Paths.stub(:sync_default_conf!, nil) { Nokizaru::Log.stub(:write, nil, &) }
    end
  end

  def settings_config
    {
      'common' => { 'timeout' => 12, 'dns_servers' => ['1.1.1.1'] },
      'ssl_cert' => { 'ssl_port' => 443 },
      'port_scan' => { 'threads' => 20 },
      'dir_enum' => { 'threads' => 10, 'redirect' => false, 'verify_ssl' => true, 'extension' => 'php,txt' }
    }
  end
end
