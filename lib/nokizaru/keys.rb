# frozen_string_literal: true

require 'json'
require_relative 'paths'
require_relative 'log'

module Nokizaru
  # Read API keys from environment first, then persisted keys file
  module KeyStore
    module_function

    def fetch(name, env: nil)
      env_value = env && ENV.fetch(env, nil)
      return env_value if present_value?(env_value)

      normalized_key_value(load_keys[name.to_s])
    rescue StandardError => e
      Log.write("[keys] Exception: #{e}")
      nil
    end

    # Read-only: a scan never writes the store, so a hand-edit typo can't cost the saved keys (-k is the writer)
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
  end
end
