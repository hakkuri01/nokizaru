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

          diff_ref = resolve_diff_reference(workspace, run_id, diff_target)
          if diff_ref[:ok]
            old_run = workspace.load_run(diff_ref[:run_id])
            run['diff'] = Nokizaru::Diff.compute(old_run, run)
            run['diff_db'] = compute_db_diff(old_run, run)
            UI.row(:info, 'Diffed against run', diff_ref[:run_id])
            print_db_diff(run['diff_db'], label: 'Ronin DB diff')
            return
          end

          UI.line(:error, diff_ref[:message].to_s)
        end

        def warn_diff_without_workspace
          UI.line(:error, 'Diff requested without an active workspace')
          UI.line(:plus, 'Enable a workspace with: --project <name>')
          UI.row(:plus, 'Workspace base', Paths.workspace_dir)
          Log.write('Diff requested without workspace; skipping')
        end

        def compute_db_diff(old_run, run)
          return {} unless old_run['db_snapshot'].is_a?(Hash) && run['db_snapshot'].is_a?(Hash)

          Nokizaru::Workspace.diff_snapshots(old_run['db_snapshot'], run['db_snapshot'])
        end

        def export_if_enabled(run, info, workspace, run_id)
          return nil unless @opts[:export]

          paths = Nokizaru::ExportManager.new.export(
            run,
            domain: info[:hostname],
            formats: export_formats,
            output: export_output(workspace, run_id)
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

        def export_output(workspace, run_id)
          custom_directory = if @opts[:cd] && !@opts[:cd].to_s.strip.empty?
                               @opts[:cd]
                             elsif workspace && run_id
                               workspace.run_dir(run_id)
                             end

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
