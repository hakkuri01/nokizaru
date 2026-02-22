# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module Nokizaru
  # Simple file-based cache with TTL
  # This intentionally keeps dependencies low and works both inside and outside
  # A persistent workspace
  class CacheStore
    # Capture constructor arguments and initialize internal state
    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(@dir)
    end

    # Build a deterministic cache key from namespace and parameters
    def key_for(parts)
      Digest::SHA256.hexdigest(Array(parts).join('|'))
    end

    # Return cached data when fresh or compute and store a new value
    def fetch(key, ttl_s: 3600)
      path = File.join(@dir, "#{key}.json")
      cached = read_cached_payload(path, ttl_s)
      return cached unless cached.nil?

      payload = yield
      write_cached_payload(path, payload)
      payload
    end

    private

    def read_cached_payload(path, ttl_s)
      return nil unless File.exist?(path)

      obj = JSON.parse(File.read(path))
      stored_at = Time.at(obj.fetch('stored_at'))
      return nil if (Time.now - stored_at) > ttl_s.to_f

      obj['payload']
    rescue StandardError
      nil
    end

    def write_cached_payload(path, payload)
      cache_data = { 'stored_at' => Time.now.to_i, 'payload' => payload }
      File.write(path, JSON.pretty_generate(cache_data))
    rescue StandardError
      nil
    end
  end
end
