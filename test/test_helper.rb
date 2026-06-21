# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'nokizaru'

module Minitest
  class Test
    def capture_stdout
      original_stdout = $stdout
      stream = StringIO.new
      $stdout = stream
      yield
      stream.string
    ensure
      $stdout = original_stdout
    end
  end
end
