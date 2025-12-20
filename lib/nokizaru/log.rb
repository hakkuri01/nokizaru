# frozen_string_literal: true

require 'logger'
require_relative 'paths'

module Nokizaru
  module Log
    module_function

    def logger
      @logger ||= begin
        Paths.ensure_dirs!
        io = File.open(Paths.log_file, 'a:UTF-8')
        io.sync = true
        l = Logger.new(io)
        l.level = Logger::INFO
        l.datetime_format = '%m/%d/%Y %I:%M:%S %p'
        l.formatter = proc do |severity, datetime, _progname, msg|
          "[#{datetime}] : #{msg}\n"
        end
        l
      end
    end

    def write(message)
      logger.info(message)
    end
  end
end
