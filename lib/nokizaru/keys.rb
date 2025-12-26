# frozen_string_literal: true

require 'json'
require_relative 'paths'
require_relative 'log'

module Nokizaru
  # - Prefer environment variables
  # - Fallback to ~/.config/nokizaru/keys.json
  # - If the key name is missing from keys.json, add it with null
  module KeyStore
    module_function

    # @param name [String, Symbol] logical key name used in keys.json
    # @param env [String, nil] environment variable to check first
    # @return [String, nil]
    def fetch(name, env: nil)
      name = name.to_s
      env_val = env && ENV[env]
      return env_val if env_val && !env_val.empty?

      begin
        keys = JSON.parse(File.read(Paths.keys_file))
      rescue StandardError => e
        Log.write("[keys] Unable to read keys.json: #{e}")
        keys = {}
      end

      if keys.key?(name)
        val = keys[name]
        return nil if val.nil? || val.to_s.empty?

        return val
      end

      # Add missing key with null
      keys[name] = nil
      File.write(Paths.keys_file, JSON.pretty_generate(keys))
      nil
    rescue StandardError => e
      Log.write("[keys] Exception: #{e}")
      nil
    end
  end
end
