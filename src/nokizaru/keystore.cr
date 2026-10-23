require "json"
require "./paths"
require "./log"

module Nokizaru
  # API keys, read from the environment first, then the persisted keys.json.
  # A scan only reads the store; the `-k` flow is the single writer, and it writes
  # through a temp file and rename so neither a reader nor a crash sees half a
  # file. A hand-edit that leaves the store unparseable is refused on save, never
  # clobbered.
  module KeyStore
    extend self

    VALID_KEYS = %w[
      alienvault bevigil binedge facebook netlas shodan virustotal zoomeye hunter chaos
      censys_api_id censys_api_secret wappalyzer
    ]

    # Raised when saving would overwrite a store that no longer parses as a JSON object.
    class UnreadableStore < Exception
    end

    def valid_name?(name : String) : Bool
      VALID_KEYS.includes?(name)
    end

    def fetch(name : String, env : String? = nil) : String?
      if env
        env_value = ENV[env]?
        return env_value if env_value && !env_value.empty?
      end
      value = load_keys[name]?
      value && !value.empty? ? value : nil
    rescue ex
      Log.write("[keys] Exception: #{ex}")
      nil
    end

    def load_keys : Hash(String, String)
      return {} of String => String unless File.exists?(Paths.keys_file)

      Hash(String, String).from_json(File.read(Paths.keys_file))
    rescue ex
      Log.write("[keys] Unable to read keys.json: #{ex}")
      {} of String => String
    end

    def save(name : String, value : String) : Nil
      store = read_store_strict
      store[name] = value
      write_store(store)
    end

    private def read_store_strict : Hash(String, String)
      return {} of String => String unless File.exists?(Paths.keys_file)

      Hash(String, String).from_json(File.read(Paths.keys_file))
    rescue JSON::ParseException
      raise UnreadableStore.new("keys.json is not a valid JSON object")
    end

    private def write_store(store : Hash(String, String)) : Nil
      path = Paths.keys_file
      Dir.mkdir_p(File.dirname(path), Paths::PRIVATE_DIR)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, store.to_pretty_json, perm: File::Permissions.new(Paths::PRIVATE_FILE))
      File.rename(temp, path)
    end
  end
end
