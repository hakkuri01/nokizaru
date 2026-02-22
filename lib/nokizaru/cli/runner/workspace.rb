# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Diffing and export helpers for workspace runs
      module Workspace
        private

        def enrich_workspace_db!(workspace, run)
          return unless workspace

          db_ingest_ok = workspace.ingest_run!(run)
          run['db_snapshot'] = workspace.db_snapshot
          db_status = build_workspace_db_status(workspace: workspace, ingest_ok: db_ingest_ok,
                                                snapshot: run['db_snapshot'])
          run['meta']['workspace']['db'] = db_status
          print_workspace_db_status(db_status)
        end

        def handle_diff!(workspace, run_id, run)
          diff_target = resolve_diff_target
          return if diff_target.nil?
          return warn_diff_without_workspace if workspace.nil?

          resolve_and_apply_diff(workspace, run_id, run, diff_target)
        end

        def warn_diff_without_workspace
          UI.line(:error, 'Diff requested without an active workspace')
          UI.line(:plus, 'Enable a workspace with: --project <name>')
          UI.row(:plus, 'Workspace base', Paths.workspace_dir)
          Log.write('Diff requested without workspace; skipping')
        end

        def resolve_and_apply_diff(workspace, run_id, run, diff_target)
          diff_ref = resolve_diff_reference(workspace, run_id, diff_target)
          return UI.line(:error, diff_ref[:message].to_s) unless diff_ref[:ok]

          apply_diff!(workspace, run, diff_ref[:run_id])
        end

        def apply_diff!(workspace, run, previous_id)
          old_run = workspace.load_run(previous_id)
          run['diff'] = Nokizaru::Diff.compute(old_run, run)
          run['diff_db'] = compute_db_diff(old_run, run)
          UI.row(:info, 'Diffed against run', previous_id)
          print_db_diff(run['diff_db'], label: 'Ronin DB diff')
        end

        def compute_db_diff(old_run, run)
          return {} unless old_run['db_snapshot'].is_a?(Hash) && run['db_snapshot'].is_a?(Hash)

          Nokizaru::Workspace.diff_snapshots(old_run['db_snapshot'], run['db_snapshot'])
        end

        def export_if_enabled(run, info, workspace, run_id)
          return nil unless @opts[:export]

          paths = perform_export(run, info, workspace, run_id)
          paths.any? ? File.dirname(paths.values.first) : nil
        rescue ArgumentError => e
          handle_export_error(e)
        end

        def perform_export(run, info, workspace, run_id)
          Nokizaru::ExportManager.new.export(
            run,
            domain: info[:hostname],
            formats: export_formats,
            output: {
              custom_directory: resolve_custom_export_directory(workspace, run_id),
              custom_basename: resolved_export_basename
            }
          )
        end

        def handle_export_error(error)
          UI.line(:error, "Export failed : #{error.message}")
          UI.line(:plus, 'Supported formats : txt,json,html')
          Log.write("[export] #{error.class}: #{error.message}")
          exit(1)
        end

        def resolved_export_basename
          value = @opts[:of].to_s.strip
          value.empty? ? nil : value
        end

        def print_run_completion(elapsed, workspace, run_id, export_dir)
          UI.row(:info, 'Completed in', "#{format('%.2f', elapsed)}s")
          UI.row(:info, 'Workspace run saved', workspace.run_dir(run_id)) if workspace && run_id
          UI.row(:info, 'Exported', export_dir) if export_dir
        end

        def export_formats
          raw = @opts[:o].to_s.strip
          return %w[txt json html] if raw.empty?

          raw.split(',').map(&:strip).reject(&:empty?).map(&:downcase).uniq
        end

        def resolve_diff_target
          return 'last' if @argv.include?('--diff') && (@opts[:diff].nil? || @opts[:diff].to_s.strip.empty?)

          value = @opts[:diff]
          return nil if value.nil?

          stripped = value.to_s.strip
          stripped.empty? ? nil : stripped
        end

        def resolve_custom_export_directory(workspace, run_id)
          return @opts[:cd] if @opts[:cd] && !@opts[:cd].to_s.strip.empty?
          return workspace.run_dir(run_id) if workspace && run_id

          nil
        end
      end
    end
  end
end
