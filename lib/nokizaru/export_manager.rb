# frozen_string_literal: true

require 'fileutils'
require_relative 'paths'
require_relative 'exporters/json'
require_relative 'exporters/html'
require_relative 'exporters/txt'

module Nokizaru
  class ExportManager
    SUPPORTED_FORMATS = %w[txt json html].freeze
    EXPORTER_CLASSES = {
      'json' => Exporters::Json,
      'html' => Exporters::Html,
      'txt' => Exporters::Txt
    }.freeze

    def export(run, domain:, formats:, output: {})
      normalized_formats = normalize_formats(formats)
      validate_formats!(normalized_formats)

      output = {
        timestamp: Time.now,
        custom_directory: nil,
        custom_basename: nil
      }.merge(output || {})
      export_dir = resolve_export_directory(domain, output[:custom_directory])
      basename = resolve_basename(output[:timestamp], output[:custom_basename])

      ensure_directory_exists(export_dir)

      write_exports(run, export_dir, basename, normalized_formats)
    end

    private

    def normalize_formats(formats)
      Array(formats)
        .flat_map { |f| f.to_s.split(',') }
        .map { |f| f.strip.downcase }
        .reject(&:empty?)
        .uniq
        .tap { |result| result << 'txt' if result.empty? }
    end

    def validate_formats!(formats)
      unsupported = formats - SUPPORTED_FORMATS
      return if unsupported.empty?

      raise ArgumentError,
            "Unsupported export format(s): #{unsupported.join(', ')}. " \
            "Supported: #{SUPPORTED_FORMATS.join(', ')}"
    end

    def resolve_export_directory(domain, custom_directory)
      return custom_directory if custom_directory && !custom_directory.to_s.strip.empty?

      Paths.target_dump_dir(domain)
    end

    def resolve_basename(timestamp, custom_basename)
      return custom_basename if custom_basename && !custom_basename.to_s.strip.empty?

      Paths.export_timestamp(timestamp)
    end

    def ensure_directory_exists(directory)
      FileUtils.mkdir_p(directory)
    end

    def write_exports(run, directory, basename, formats)
      formats.each_with_object({}) do |format, paths|
        path = build_export_path(directory, basename, format)
        write_single_export(run, path, format)
        paths[format] = path
      end
    end

    def build_export_path(directory, basename, format)
      File.join(directory, "#{basename}.#{format}")
    end

    def write_single_export(run, path, format)
      exporter_class = EXPORTER_CLASSES[format]
      exporter_class.new.write(run, path)
    end
  end
end
