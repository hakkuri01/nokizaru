# frozen_string_literal: true

require 'fileutils'

module Nokizaru
  module Paths
    APP_DIR = 'nokizaru'

    def self.home
      @home ||= Dir.home
    end

    def self.project_root
      @project_root ||= File.expand_path('../..', __dir__)
    end

    def self.user_data_dir
      @user_data_dir ||= ensure_dir(xdg_dir('XDG_DATA_HOME', '.local/share'))
    end

    def self.config_dir
      @config_dir ||= ensure_dir(xdg_dir('XDG_CONFIG_HOME', '.config'))
    end

    def self.dumps_dir
      @dumps_dir ||= ensure_dir(File.join(user_data_dir, 'dumps'))
    end

    def self.target_dump_dir(domain)
      ensure_dir(File.join(dumps_dir, "nk_#{sanitize_domain_for_path(domain)}"))
    end

    def self.export_timestamp(time = Time.now)
      time.strftime('%Y-%m-%d_%H-%M-%S')
    end

    def self.sanitize_domain_for_path(domain)
      return 'unknown' if domain.nil? || domain.to_s.strip.empty?

      sanitized = domain.to_s.strip.downcase
      sanitized = sanitized.gsub(%r{[/\\:*?"<>|]}, '_').squeeze('.')
      sanitized = sanitized.gsub(/\A\.+|\.+\z/, '').slice(0, 128)
      sanitized.empty? ? 'unknown' : sanitized
    end

    def self.ensure_dir(path)
      FileUtils.mkdir_p(path)
      path
    end

    def self.xdg_dir(env_key, fallback_suffix)
      env = ENV.fetch(env_key, nil)
      base = env && !env.empty? ? env : File.join(home, fallback_suffix)
      File.join(base, APP_DIR)
    end

    private_class_method :sanitize_domain_for_path, :ensure_dir, :xdg_dir
  end
end

require_relative 'paths/templates'
require_relative 'paths/files'
