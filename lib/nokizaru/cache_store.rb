# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module Nokizaru
  # Simple file-based cache with TTL.
  #
  # This intentionally keeps dependencies low and works both inside and outside
  # a persistent workspace.
  class CacheStore
    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(@dir)
    end

    def key_for(parts)
      Digest::SHA256.hexdigest(Array(parts).join('|'))
    end

    def fetch(key, ttl_s: 3600)
      path = File.join(@dir, "#{key}.json")
      if File.exist?(path)
        begin
          obj = JSON.parse(File.read(path))
          stored_at = Time.at(obj.fetch('stored_at'))
          return obj['payload'] if (Time.now - stored_at) <= ttl_s.to_f
        rescue StandardError
          # treat as cache miss
        end
      end

      payload = yield
      begin
        File.write(path, JSON.pretty_generate({
                                                'stored_at' => Time.now.to_i,
                                                'payload' => payload
                                              }))
      rescue StandardError
        # ignore cache write failures
      end
      payload
    end
  end
end
