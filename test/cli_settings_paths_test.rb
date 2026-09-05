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

  def test_paths_sanitize_domains_for_safe_dump_directories
    assert_equal 'unknown', Nokizaru::Paths.send(:sanitize_domain_for_path, nil)
    assert_equal 'example.com', Nokizaru::Paths.send(:sanitize_domain_for_path, '..Example.COM..')
    assert_equal 'bad_path_name', Nokizaru::Paths.send(:sanitize_domain_for_path, 'bad/path:name')
    assert_equal 128, Nokizaru::Paths.send(:sanitize_domain_for_path, 'a' * 200).length
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

  private

  def settings_config
    {
      'common' => { 'timeout' => 12, 'dns_servers' => ['1.1.1.1'] },
      'ssl_cert' => { 'ssl_port' => 443 },
      'port_scan' => { 'threads' => 20 },
      'dir_enum' => { 'threads' => 10, 'redirect' => false, 'verify_ssl' => true, 'extension' => 'php,txt' }
    }
  end
end
