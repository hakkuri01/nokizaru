# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative 'paths'

module Nokizaru
  module Log
    # Append log entries with timestamps for troubleshooting and auditability
    def self.write(message)
      path = Paths.log_file
      FileUtils.mkdir_p(File.dirname(path))

      line = "[#{Time.now.utc.iso8601}] #{message}\n"
      File.open(path, 'a') { |f| f.write(line) }
    rescue StandardError
      # Logging should never break the tool
      nil
    end
  end
end
