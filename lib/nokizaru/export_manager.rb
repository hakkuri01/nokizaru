# frozen_string_literal: true

require 'fileutils'
require_relative 'exporters/json'
require_relative 'exporters/html'
require_relative 'exporters/txt'

module Nokizaru
  class ExportManager
    SUPPORTED = %w[txt json html].freeze

    def export(run, formats:, directory:, basename: 'nokizaru')
      formats = Array(formats).flat_map { |f| f.to_s.split(',') }.map { |f| f.strip.downcase }.reject(&:empty?)
      formats = ['txt'] if formats.empty?
      unknown = formats - SUPPORTED
      unless unknown.empty?
        raise ArgumentError, "Unsupported export format(s): #{unknown.join(', ')}. Supported: #{SUPPORTED.join(', ')}"
      end

      FileUtils.mkdir_p(directory)

      paths = {}
      formats.each do |fmt|
        path = File.join(directory, "#{basename}.#{fmt}")
        case fmt
        when 'json'
          Exporters::Json.new.write(run, path)
        when 'html'
          Exporters::Html.new.write(run, path)
        when 'txt'
          Exporters::Txt.new.write(run, path)
        end
        paths[fmt] = path
      end
      paths
    end
  end
end
