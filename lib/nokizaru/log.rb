# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative 'paths'

module Nokizaru
  module Log
    def self.write(message)
      path = Paths.log_file
      FileUtils.mkdir_p(File.dirname(path), mode: Paths::PRIVATE_DIR)

      line = "[#{Time.now.utc.iso8601}] #{message}\n"
      Fiber.blocking { File.open(path, 'a', Paths::PRIVATE_FILE) { |file| file.write(line) } }
    rescue StandardError
      # Logging should never break the tool
      nil
    end
  end
end
