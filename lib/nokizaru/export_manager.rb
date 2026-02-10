# frozen_string_literal: true

require 'fileutils'
require_relative 'paths'
require_relative 'exporters/json'
require_relative 'exporters/html'
require_relative 'exporters/txt'

module Nokizaru
  # Coordinates exporting scan results to multiple formats
  class ExportManager
    SUPPORTED_FORMATS = %w[txt json html].freeze
    EXPORTER_CLASSES = {
      'json' => Exporters::Json,
      'html' => Exporters::Html,
      'txt' => Exporters::Txt
    }.freeze

    # Exports scan results to the specified formats
    # Normalize formats, resolve output paths, and write each requested export file
    def export(run, domain:, formats:, timestamp: nil, custom_directory: nil, custom_basename: nil)
      normalized_formats = normalize_formats(formats)
      validate_formats!(normalized_formats)

      timestamp ||= Time.now
      export_dir = resolve_export_directory(domain, custom_directory)
      basename = resolve_basename(timestamp, custom_basename)

      ensure_directory_exists(export_dir)

      write_exports(run, export_dir, basename, normalized_formats)
    end

    private

    # Normalizes format input to an array of lowercase format strings
    def normalize_formats(formats)
      Array(formats)
        .flat_map { |f| f.to_s.split(',') }
        .map { |f| f.strip.downcase }
        .reject(&:empty?)
        .uniq
        .tap { |result| result << 'txt' if result.empty? }
    end

    # Validates that all requested formats are supported
    def validate_formats!(formats)
      unsupported = formats - SUPPORTED_FORMATS
      return if unsupported.empty?

      raise ArgumentError,
            "Unsupported export format(s): #{unsupported.join(', ')}. " \
            "Supported: #{SUPPORTED_FORMATS.join(', ')}"
    end

    # Resolves the export directory, using custom override or computing from domain
    def resolve_export_directory(domain, custom_directory)
      return custom_directory if custom_directory && !custom_directory.to_s.strip.empty?

      Paths.target_dump_dir(domain)
    end

    # Resolves the basename for export files, using custom override or timestamp
    def resolve_basename(timestamp, custom_basename)
      return custom_basename if custom_basename && !custom_basename.to_s.strip.empty?

      Paths.export_timestamp(timestamp)
    end

    # Ensures the export directory exists
    def ensure_directory_exists(directory)
      FileUtils.mkdir_p(directory)
    end

    # Writes exports for all requested formats and returns the paths
    def write_exports(run, directory, basename, formats)
      formats.each_with_object({}) do |format, paths|
        path = build_export_path(directory, basename, format)
        write_single_export(run, path, format)
        paths[format] = path
      end
    end

    # Builds the full export file path
    def build_export_path(directory, basename, format)
      File.join(directory, "#{basename}.#{format}")
    end

    # Writes a single export file using the appropriate exporter
    def write_single_export(run, path, format)
      exporter_class = EXPORTER_CLASSES[format]
      exporter_class.new.write(run, path)
    end
  end
end
