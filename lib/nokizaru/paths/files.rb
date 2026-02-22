# frozen_string_literal: true

require 'json'

module Nokizaru
  # Runtime file paths and bootstrap helpers for local data
  module Paths
    def self.metadata_file
      File.join(user_data_dir, 'metadata.json')
    end

    def self.keys_file
      File.join(user_data_dir, 'keys.json')
    end

    def self.config_file
      File.join(config_dir, 'config.json')
    end

    def self.log_file
      File.join(user_data_dir, 'nokizaru.log')
    end

    def self.whois_servers_file
      File.join(user_data_dir, 'whois_servers.json')
    end

    def self.sync_default_conf!
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(user_data_dir)
      ensure_file!(config_file, default_config_template) { {} }
      ensure_file!(keys_file, default_keys_template) { {} }
      ensure_file!(metadata_file, default_metadata_template) { {} }
      ensure_file!(whois_servers_file, default_whois_servers_template) { {} }
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

    private_class_method :backup_config!, :ensure_file!
  end
end
