# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'paths'

module Nokizaru
  # Ensure ~/.config/nokizaru exists and is seeded with default conf/
  # Ensure ~/.local/share/nokizaru/dumps/ exists
  # Load config.json and expose expected keys
  module Settings
    module_function

    # Load configuration from disk and keep defaults when values are missing
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
      common, ssl_cert, port_scan, dir_enum, export = config_sections(config_json)
      assign_common_values(common, ssl_cert, port_scan)
      assign_dir_enum_values(dir_enum)
      @dir_enum_wordlist = File.join(Paths.project_root, 'wordlists', 'dirb_common.txt')
      @export_format = export.fetch('format')
    end

    def config_sections(config_json)
      [
        config_json.fetch('common'),
        config_json.fetch('ssl_cert'),
        config_json.fetch('port_scan'),
        config_json.fetch('dir_enum'),
        config_json.fetch('export')
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

    # Return timeout setting with a safe numeric fallback
    def timeout = @timeout
    # Return configured DNS resolver list for enumeration modules
    def custom_dns = @custom_dns
    # Return configured SSL port used by certificate collection
    def ssl_port = @ssl_port
    # Return thread count used by port scanning workers
    def port_scan_threads = @port_scan_threads
    # Return thread count used by directory enumeration workers
    def dir_enum_threads = @dir_enum_threads
    # Return redirect handling preference for directory enumeration
    def dir_enum_redirect = @dir_enum_redirect
    # Return SSL verification preference for directory enumeration
    def dir_enum_verify_ssl = @dir_enum_verify_ssl
    # Return configured extension list for directory enumeration variants
    def dir_enum_extension = @dir_enum_extension
    # Return wordlist path used by directory enumeration
    def dir_enum_wordlist = @dir_enum_wordlist
    # Return configured default export format list
    def export_format = @export_format
  end
end
