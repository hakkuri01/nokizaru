# frozen_string_literal: true

require 'fileutils'
require 'json'

begin
  require 'ronin/support/home'
rescue LoadError
  # Ronin-support is optional at runtime; fall back to manual XDG paths
end

module Nokizaru
  # Centralized paths for Nokizaru runtime state and shipped templates
  module Paths
    APP_DIR = 'nokizaru'

    # Resolve the user home directory for all persistent Nokizaru paths
    def self.home
      @home ||= Dir.home
    end

    # Resolve repository root used for bundled default assets
    def self.project_root
      @project_root ||= File.expand_path('../..', __dir__)
    end

    # ~/.Local/share/nokizaru
    def self.user_data_dir
      @user_data_dir ||= begin
        base =
          if defined?(Ronin::Support::Home)
            # Ronin-support expects ONE arg (app name) for XDG helpers
            Ronin::Support::Home.local_share_dir(APP_DIR)
          else
            File.join(home, '.local', 'share', APP_DIR)
          end

        FileUtils.mkdir_p(base)
        base
      end
    end

    # ~/.Config/nokizaru
    def self.config_dir
      @config_dir ||= begin
        base =
          if defined?(Ronin::Support::Home)
            Ronin::Support::Home.config_dir(APP_DIR)
          else
            xdg = ENV['XDG_CONFIG_HOME']
            File.join(xdg && !xdg.empty? ? xdg : File.join(home, '.config'), APP_DIR)
          end

        FileUtils.mkdir_p(base)
        base
      end
    end

    # ~/.Cache/nokizaru
    def self.cache_dir
      @cache_dir ||= begin
        base =
          if defined?(Ronin::Support::Home)
            Ronin::Support::Home.cache_dir(APP_DIR)
          else
            xdg = ENV['XDG_CACHE_HOME']
            File.join(xdg && !xdg.empty? ? xdg : File.join(home, '.cache'), APP_DIR)
          end

        FileUtils.mkdir_p(base)
        base
      end
    end

    # ~/.Local/share/nokizaru/workspaces
    def self.workspace_dir
      @workspace_dir ||= begin
        base = File.join(user_data_dir, 'workspaces')
        FileUtils.mkdir_p(base)
        base
      end
    end

    # ~/.Local/share/nokizaru/dumps
    def self.dumps_dir
      @dumps_dir ||= begin
        base = File.join(user_data_dir, 'dumps')
        FileUtils.mkdir_p(base)
        base
      end
    end

    # ~/.Local/share/nokizaru/dumps/nk_<domain>
    def self.target_dump_dir(domain)
      sanitized = sanitize_domain_for_path(domain)
      dir = File.join(dumps_dir, "nk_#{sanitized}")
      FileUtils.mkdir_p(dir)
      dir
    end

    # Generates a filesystem-safe, sortable timestamp string
    # Format: YYYY-MM-DD_HH-MM-SS
    def self.export_timestamp(time = Time.now)
      time.strftime('%Y-%m-%d_%H-%M-%S')
    end

    # Removes or replaces characters that could cause issues
    def self.sanitize_domain_for_path(domain)
      return 'unknown' if domain.nil? || domain.to_s.strip.empty?

      # Replace path separators and problematic characters
      sanitized = domain.to_s.strip.downcase
      sanitized = sanitized.gsub(%r{[/\\:*?"<>|]}, '_')
      sanitized = sanitized.gsub(/\.+/, '.')
      sanitized = sanitized.gsub(/\A\.+|\.+\z/, '')
      sanitized = sanitized.slice(0, 128) # Limit length for filesystem compatibility
      sanitized.empty? ? 'unknown' : sanitized
    end

    private_class_method :sanitize_domain_for_path

    # --- Files Nokizaru expects under user dirs ---
    def self.metadata_file
      File.join(user_data_dir, 'metadata.json')
    end

    # Resolve the active keys file path and ensure defaults are synced
    def self.keys_file
      File.join(user_data_dir, 'keys.json')
    end

    # Resolve the active config file path and ensure defaults are synced
    def self.config_file
      File.join(config_dir, 'config.json')
    end

    # Resolve the active log file path in the user data directory
    def self.log_file
      File.join(user_data_dir, 'nokizaru.log')
    end

    # Resolve the whois servers data file path used by lookups
    def self.whois_servers_file
      File.join(user_data_dir, 'whois_servers.json')
    end

    # --- Defaults shipped with the repo ---
    def self.default_config_template
      candidates = [
        File.join(project_root, 'conf', 'config.json'),
        File.join(project_root, 'metadata', 'config.json')
      ]
      candidates.find { |p| File.exist?(p) }
    end

    # Build default keys template with all known provider names
    def self.default_keys_template
      candidates = [
        File.join(project_root, 'conf', 'keys.json'),
        File.join(project_root, 'metadata', 'keys.json')
      ]
      candidates.find { |p| File.exist?(p) }
    end

    # Build default metadata template for local runtime state
    def self.default_metadata_template
      candidates = [
        File.join(project_root, 'data', 'metadata.json'),
        File.join(project_root, 'metadata', 'metadata.json')
      ]
      candidates.find { |p| File.exist?(p) }
    end

    # Build fallback whois server mappings for common TLDs
    def self.default_whois_servers_template
      candidates = [
        File.join(project_root, 'data', 'whois_servers.json'),
        File.join(project_root, 'data', 'whois-servers.json'),
        File.join(project_root, 'metadata', 'whois_servers.json'),
        File.join(project_root, 'metadata', 'whois-servers.json')
      ]
      candidates.find { |p| File.exist?(p) }
    end

    # Ensure config + keys + supporting data exist under XDG dirs by copying from repo templates
    # This is called by Settings.load!
    def self.sync_default_conf!
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(user_data_dir)

      ensure_file!(config_file, default_config_template) { {} }
      ensure_file!(keys_file, default_keys_template) { {} }
      ensure_file!(metadata_file, default_metadata_template) { {} }
      ensure_file!(whois_servers_file, default_whois_servers_template) { {} }

      true
    end

    # Restores the default config.json from the shipped template
    def self.restore_default_config!(backup: true)
      tmpl = default_config_template
      raise "Default config template not found under #{project_root}" unless tmpl

      FileUtils.mkdir_p(config_dir)

      if backup && File.exist?(config_file)
        ts = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
        FileUtils.cp(config_file, "#{config_file}.bak.#{ts}")
      end

      FileUtils.cp(tmpl, config_file)
      true
    end

    # Write file defaults only when missing to preserve user changes
    def self.ensure_file!(dest, template_path, &fallback_block)
      return if File.exist?(dest)

      if template_path && File.exist?(template_path)
        FileUtils.cp(template_path, dest)
      else
        data = fallback_block ? fallback_block.call : {}
        File.write(dest, JSON.pretty_generate(data))
      end
    end

    private_class_method :ensure_file!
  end
end
