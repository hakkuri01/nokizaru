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
        config_json = JSON.parse(File.read(Paths.config_file))

        common    = config_json.fetch('common')
        ssl_cert  = config_json.fetch('ssl_cert')
        port_scan = config_json.fetch('port_scan')
        dir_enum  = config_json.fetch('dir_enum')
        export    = config_json.fetch('export')

        @timeout            = common.fetch('timeout')
        @custom_dns         = common.fetch('dns_servers')
        @ssl_port           = ssl_cert.fetch('ssl_port')
        @port_scan_threads  = port_scan.fetch('threads')

        @dir_enum_threads    = dir_enum.fetch('threads')
        @dir_enum_redirect   = dir_enum.fetch('redirect')
        @dir_enum_verify_ssl = dir_enum.fetch('verify_ssl')
        @dir_enum_extension  = dir_enum.fetch('extension')

        @dir_enum_wordlist = File.join(Paths.project_root, 'wordlists', 'dirb_common.txt')
        @export_format     = export.fetch('format')
      rescue JSON::ParserError, KeyError
        # Config file is invalid JSON or missing required keys
        # Restore default config.json (backup existing) and retry
        Paths.restore_default_config!(backup: true)
        retry
      end

      self
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
