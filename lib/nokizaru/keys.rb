# frozen_string_literal: true

require 'json'
require_relative 'paths'
require_relative 'log'

module Nokizaru
  # Read API keys from environment first, then persisted keys file
  module KeyStore
    module_function

    def fetch(name, env: nil)
      key_name = name.to_s
      env_value = env && ENV.fetch(env, nil)
      return env_value if present_value?(env_value)

      keys = load_keys
      return normalized_key_value(keys[key_name]) if keys.key?(key_name)

      seed_missing_key!(keys, key_name)
      nil
    rescue StandardError => e
      Log.write("[keys] Exception: #{e}")
      nil
    end

    def load_keys
      JSON.parse(File.read(Paths.keys_file))
    rescue StandardError => e
      Log.write("[keys] Unable to read keys.json: #{e}")
      {}
    end

    def present_value?(value)
      !value.nil? && !value.empty?
    end

    def normalized_key_value(value)
      present_value?(value.to_s) ? value : nil
    end

    def seed_missing_key!(keys, key_name)
      keys[key_name] = nil
      File.write(Paths.keys_file, JSON.pretty_generate(keys))
    end
  end
end
