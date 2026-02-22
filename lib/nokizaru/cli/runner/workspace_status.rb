# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Workspace status and diff resolution helpers
      module WorkspaceStatus
        private

        def build_workspace_db_status(workspace:, ingest_ok:, snapshot:)
          available = workspace.db_available?
          error = workspace.last_db_error.to_s.strip
          {
            'state' => db_state(available, error, ingest_ok),
            'available' => available,
            'ingest_ok' => !ingest_ok.nil?,
            'snapshot_collections' => snapshot.is_a?(Hash) ? snapshot.keys.length : 0,
            'error' => error
          }
        end

        def db_state(available, error, ingest_ok)
          return 'unavailable' unless available
          return 'enabled' if error.empty? && ingest_ok

          'degraded'
        end

        def print_workspace_db_status(db_status)
          state = db_status['state'].to_s
          message = workspace_db_message(state, db_status['error'].to_s, db_status['snapshot_collections'])
          level = state == 'enabled' ? :info : :error
          UI.row(level, 'Workspace DB', message)
        end

        def workspace_db_message(state, error, collections)
          return "enabled (collections: #{collections})" if state == 'enabled'
          return "unavailable (#{error.empty? ? 'ronin-db not installed' : error})" if state == 'unavailable'

          "degraded (#{error.empty? ? 'partial ingest/snapshot failure' : error})"
        end

        def resolve_diff_reference(workspace, run_id, diff_target)
          return resolve_last_diff_reference(workspace, run_id) if diff_target == 'last'

          requested_id = diff_target.to_s
          unless workspace.run_ids.include?(requested_id)
            return { ok: false,
                     message: "Diff run ID not found: #{requested_id}" }
          end

          resolve_existing_results(workspace, requested_id)
        end

        def resolve_last_diff_reference(workspace, run_id)
          prev_id = workspace.previous_run_id(run_id)
          return { ok: false, message: 'No prior run found in this workspace.' } unless prev_id

          resolve_existing_results(workspace, prev_id)
        end

        def resolve_existing_results(workspace, run_id)
          return { ok: true, run_id: run_id } if File.exist?(workspace.results_path(run_id))

          { ok: false, message: "Run #{run_id} is missing results.json; cannot diff." }
        end
      end
    end
  end
end
