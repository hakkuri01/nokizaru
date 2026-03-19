# frozen_string_literal: true

require 'minitest/autorun'
require 'uri'
require_relative '../lib/nokizaru'

module Minitest
  class Test
    def teardown
      Nokizaru::ConnectionPool.reset!
    end
  end
end
