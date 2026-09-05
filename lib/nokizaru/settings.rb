# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'paths'

module Nokizaru
  # Bootstrap local config/data directories and expose configuration values
  module Settings
    module_function

    WORDLISTS = {
      'small' => 'raft_small-dir_2k.txt',
      'medium' => 'raft_med-dir_5k.txt',
      'large' => 'raft_big-dir_10k.txt'
    }.freeze

    def load!
      Paths.sync_default_conf!

      begin
        assign_values(load_config_file)
      rescue JSON::ParserError, KeyError
        Paths.restore_default_config!(backup: true)
        retry
      end

      self
    end

    def load_config_file
      JSON.parse(File.read(Paths.config_file))
    end

    def assign_values(config_json)
      common, ssl_cert, port_scan, dir_enum = config_sections(config_json)
      assign_common_values(common, ssl_cert, port_scan)
      assign_dir_enum_values(dir_enum)
      @dir_enum_wordlist = curated_wordlist('medium')
    end

    def config_sections(config_json)
      [
        config_json.fetch('common'),
        config_json.fetch('ssl_cert'),
        config_json.fetch('port_scan'),
        config_json.fetch('dir_enum')
      ]
    end

    def assign_common_values(common, ssl_cert, port_scan)
      @timeout = common.fetch('timeout')
      @custom_dns = common.fetch('dns_servers')
      @ssl_port = ssl_cert.fetch('ssl_port')
      @port_scan_threads = port_scan.fetch('threads')
    end

    def assign_dir_enum_values(dir_enum)
      @dir_enum_threads = dir_enum.fetch('threads')
      @dir_enum_redirect = dir_enum.fetch('redirect')
      @dir_enum_verify_ssl = dir_enum.fetch('verify_ssl')
      @dir_enum_extension = dir_enum.fetch('extension')
    end

    def timeout = @timeout
    def custom_dns = @custom_dns
    def ssl_port = @ssl_port
    def port_scan_threads = @port_scan_threads
    def dir_enum_threads = @dir_enum_threads
    def dir_enum_redirect = @dir_enum_redirect
    def dir_enum_verify_ssl = @dir_enum_verify_ssl
    def dir_enum_extension = @dir_enum_extension
    def dir_enum_wordlist = @dir_enum_wordlist

    # Resolve a curated size name while preserving custom paths
    def wordlist(value)
      WORDLISTS.key?(value.to_s.downcase) ? curated_wordlist(value) : value.to_s
    end

    def curated_wordlist(size)
      File.join(Paths.project_root, 'wordlists', WORDLISTS.fetch(size.to_s.downcase))
    end

    private_class_method :curated_wordlist
  end
end
