module Nokizaru
  # XDG-based locations for the key store, runtime log, and exports. Directories
  # are created owner-only, as XDG asks, because they can hold API keys, target
  # cookies, and private scan data.
  module Paths
    extend self

    APP_DIR      = "nokizaru"
    PRIVATE_DIR  = 0o700
    PRIVATE_FILE = 0o600

    def home : String
      ENV["HOME"]? || Path.home.to_s
    end

    def xdg_dir(env_key : String, fallback_suffix : String) : String
      env = ENV[env_key]?
      base = env && !env.empty? ? env : File.join(home, fallback_suffix)
      File.join(base, APP_DIR)
    end

    def user_data_dir : String
      ensure_dir(xdg_dir("XDG_DATA_HOME", ".local/share"))
    end

    def config_dir : String
      ensure_dir(xdg_dir("XDG_CONFIG_HOME", ".config"))
    end

    def exports_dir : String
      ensure_dir(File.join(user_data_dir, "exports"))
    end

    def target_export_dir(domain : String?) : String
      ensure_dir(File.join(exports_dir, sanitize_domain_for_path(domain)))
    end

    def log_file : String
      File.join(user_data_dir, "nokizaru.log")
    end

    def keys_file : String
      File.join(user_data_dir, "keys.json")
    end

    def config_file : String
      File.join(config_dir, "config.json")
    end

    def export_timestamp(time : Time = Time.local) : String
      time.to_s("%Y-%m-%d_%H-%M-%S")
    end

    def sanitize_domain_for_path(domain : String?) : String
      return "unknown" if domain.nil? || domain.strip.empty?

      sanitized = domain.strip.downcase
      sanitized = sanitized.gsub(/[\/\\:*?"<>|]/, "_").squeeze('.')
      sanitized = sanitized.gsub(/\A\.+|\.+\z/, "")[0, 128]
      sanitized.empty? ? "unknown" : sanitized
    end

    def ensure_dir(path : String) : String
      Dir.mkdir_p(path, PRIVATE_DIR)
      path
    end
  end
end
