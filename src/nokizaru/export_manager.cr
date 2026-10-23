require "./paths"
require "./run_state"
require "./exporters/json"
require "./exporters/html"
require "./exporters/txt"

module Nokizaru
  # Writes the typed run to the requested export formats. `prepare` performs every
  # check that can fail before a byte is written (formats, filename, directory),
  # so the runner can validate the export destination up front and fail a bad
  # option before a multi-minute scan rather than after it. `export` runs the
  # checks and then writes each format.
  class ExportManager
    SUPPORTED_FORMATS = %w[txt json html]

    # Writes each requested format and returns a format => path map. The map is
    # ordered by the normalized format list, so `File.dirname(paths.first)` yields
    # the export directory for the completion line.
    def export(
      run : RunState,
      domain : String?,
      formats : Enumerable(String),
      custom_directory : String? = nil,
      custom_basename : String? = nil,
      timestamp : Time = Time.local,
    ) : Hash(String, String)
      directory, basename, normalized = prepare(
        domain: domain,
        formats: formats,
        custom_directory: custom_directory,
        custom_basename: custom_basename,
        timestamp: timestamp,
      )
      write_exports(run, directory, basename, normalized)
    end

    # Everything that can fail before results are written: normalizes and
    # validates the formats, resolves the basename (rejecting path-bearing names),
    # and creates the owner-only export directory. Returns the directory, the
    # basename, and the normalized formats.
    def prepare(
      domain : String?,
      formats : Enumerable(String),
      custom_directory : String? = nil,
      custom_basename : String? = nil,
      timestamp : Time = Time.local,
    ) : {String, String, Array(String)}
      normalized = normalize_formats(formats)
      validate_formats!(normalized)
      directory = resolve_export_directory(domain, custom_directory)
      basename = resolve_basename(timestamp, custom_basename)
      Paths.ensure_dir(directory)
      {directory, basename, normalized}
    end

    private def normalize_formats(formats : Enumerable(String)) : Array(String)
      normalized = formats
        .flat_map(&.split(','))
        .map(&.strip.downcase)
        .reject(&.empty?)
        .uniq!
      normalized << "txt" if normalized.empty?
      normalized
    end

    private def validate_formats!(formats : Array(String)) : Nil
      unsupported = formats - SUPPORTED_FORMATS
      return if unsupported.empty?

      raise ArgumentError.new(
        "Unsupported export format(s): #{unsupported.join(", ")}. Supported: #{SUPPORTED_FORMATS.join(", ")}"
      )
    end

    private def resolve_export_directory(domain : String?, custom_directory : String?) : String
      return custom_directory if custom_directory && !custom_directory.strip.empty?

      Paths.target_export_dir(domain)
    end

    # Security: a basename carrying a separator or a leading dot could place the
    # file outside the export directory (for example `-of ../../keys` over the key
    # store), so only a plain file name is accepted (cost: one match per run).
    private def resolve_basename(timestamp : Time, custom_basename : String?) : String
      name = (custom_basename || "").strip
      return Paths.export_timestamp(timestamp) if name.empty?
      raise ArgumentError.new("Export filename must be a plain name: #{name}") if name.matches?(/[\/\\]|\A\./)

      name
    end

    private def write_exports(
      run : RunState,
      directory : String,
      basename : String,
      formats : Array(String),
    ) : Hash(String, String)
      paths = {} of String => String
      formats.each do |format|
        path = File.join(directory, "#{basename}.#{format}")
        write_single_export(run, path, format)
        paths[format] = path
      end
      paths
    end

    private def write_single_export(run : RunState, path : String, format : String) : Nil
      case format
      when "json" then Exporters::Json.write(run, path)
      when "html" then Exporters::Html.write(run, path)
      when "txt"  then Exporters::Txt.write(run, path)
      end
    end
  end
end
