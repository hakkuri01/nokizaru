# frozen_string_literal: true

require 'tmpdir'

require_relative 'test_helper'

class CacheStoreTest < Minitest::Test
  def test_write_and_read_roundtrip
    Dir.mktmpdir('nokizaru-cache-test') do |dir|
      cache = Nokizaru::CacheStore.new(dir)
      key = cache.key_for(%w[dirrec hostility github.com])
      payload = { 'mode' => 'seeded', 'pressure_score' => 3 }

      cache.write(key, payload)

      assert_equal payload, cache.read(key, ttl_s: 60)
    end
  end
end
