# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      module Exporting
        private

        def export_if_enabled(run, info)
          return nil unless @opts[:export]

          paths = Nokizaru::ExportManager.new.export(
            run,
            domain: info[:hostname],
            formats: export_formats,
            output: export_output
          )
          paths.any? ? File.dirname(paths.values.first) : nil
        rescue ArgumentError => e
          handle_export_error(e)
        end

        def handle_export_error(error)
          UI.line(:error, "Export failed : #{error.message}")
          UI.line(:plus, 'Supported formats : txt,json,html')
          Log.write("[export] #{error.class}: #{error.message}")
          exit(1)
        end

        def print_run_completion(elapsed, export_dir)
          UI.row(:info, 'Completed in', "#{format('%.2f', elapsed)}s")
          UI.row(:info, 'Exported', export_dir) if export_dir
        end

        def export_formats
          raw = @opts[:o].to_s.strip
          return %w[txt json html] if raw.empty?

          raw.split(',').map(&:strip).reject(&:empty?).map(&:downcase).uniq
        end

        def export_output
          custom_directory = @opts[:cd] unless @opts[:cd].to_s.strip.empty?
          custom_basename = @opts[:of].to_s.strip
          {
            custom_directory: custom_directory,
            custom_basename: custom_basename.empty? ? nil : custom_basename
          }
        end
      end
    end
  end
end
