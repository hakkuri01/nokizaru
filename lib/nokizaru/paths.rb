# frozen_string_literal: true

require 'fileutils'

module Nokizaru
  module Paths
    module_function

    def home
      ENV.fetch('HOME')
    end

    def user_data_dir
      File.join(home, '.local', 'share', 'nokizaru', 'dumps') + '/'
    end

    def config_dir
      File.join(home, '.config', 'nokizaru')
    end

    # Root directory of the installed gem/project.
    def project_root
      File.expand_path('../..', __dir__)
    end

    def default_conf_dir
      File.join(project_root, 'conf') + '/'
    end

    def metadata_file
      File.join(project_root, 'data', 'metadata.json')
    end

    def whois_servers_file
      File.join(project_root, 'data', 'whois_servers.json')
    end

    def keys_file
      File.join(config_dir, 'keys.json')
    end

    def config_file
      File.join(config_dir, 'config.json')
    end

    def log_file
      File.join(home, '.local', 'share', 'nokizaru', 'run.log')
    end

    def ensure_dirs!
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(File.dirname(log_file))
      FileUtils.mkdir_p(user_data_dir)
    end

    # Seed defaults into ~/.config/nokizaru only if missing.
    # Never overwrite user config/keys on normal runs.
    def sync_default_conf!
      ensure_dirs!

      Dir[File.join(default_conf_dir, '*')].each do |src|
        next if File.directory?(src)

        dest = File.join(config_dir, File.basename(src))
        FileUtils.cp(src, dest) unless File.exist?(dest)
      end
    end

    # Restore default config.json into ~/.config/nokizaru/config.json.
    # Optionally backs up the existing user config as config.json.bak.
    def restore_default_config!(backup: true)
      ensure_dirs!

      src = File.join(default_conf_dir, 'config.json')
      dest = config_file

      if backup && File.exist?(dest)
        FileUtils.cp(dest, dest + '.bak')
      end

      FileUtils.cp(src, dest)
    end
  end
end
