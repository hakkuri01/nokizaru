# frozen_string_literal: true

require 'json'

module Nokizaru
  module Paths
    def self.keys_file
      File.join(user_data_dir, 'keys.json')
    end

    def self.config_file
      File.join(config_dir, 'config.json')
    end

    def self.log_file
      File.join(user_data_dir, 'nokizaru.log')
    end

    def self.sync_default_conf!
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(user_data_dir)
      ensure_file!(config_file, default_config_template) { {} }
      ensure_file!(keys_file, default_keys_template) { {} }
      secure_keys_file!
    end

    def self.restore_default_config!(backup: true)
      template = default_config_template
      raise "Default config template not found under #{project_root}" unless template

      FileUtils.mkdir_p(config_dir)
      backup_config! if backup && File.exist?(config_file)
      FileUtils.cp(template, config_file)
      config_file
    end

    def self.backup_config!
      ts = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      FileUtils.cp(config_file, "#{config_file}.bak.#{ts}")
    end

    def self.ensure_file!(dest, template_path)
      return if File.exist?(dest)

      if template_path && File.exist?(template_path)
        FileUtils.cp(template_path, dest)
      else
        File.write(dest, JSON.pretty_generate(block_given? ? yield : {}))
      end
    end

    def self.secure_keys_file!
      # Security: owner-only mode blocks local credential disclosure for one chmod per write/startup
      File.chmod(0o600, keys_file)
    end

    private_class_method :backup_config!, :ensure_file!
  end
end
