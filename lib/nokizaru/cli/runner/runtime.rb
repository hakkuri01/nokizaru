# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Runtime setup and workspace/cache construction helpers
      module Runtime
        private

        def initialize_runtime!
          Log.write('Importing config...')
          Settings.load!
          log_runtime_paths
          Log.write("Nokizaru v#{Nokizaru::VERSION}")
          banner unless @opts[:nb]
          save_key(@opts[:k]) if @opts[:k]
        end

        def log_runtime_paths
          Log.write(
            "PATHS = HOME:#{Paths.home}, SCRIPT_LOC:#{Paths.project_root}, " \
            "METADATA:#{Paths.metadata_file}, KEYS:#{Paths.keys_file}, " \
            "CONFIG:#{Paths.config_file}, LOG:#{Paths.log_file}"
          )
        end

        def build_workspace(info)
          project = @opts[:project].to_s.strip
          return nil if project.empty?

          Nokizaru::Workspace.new(project, info[:hostname])
        end

        def build_cache(workspace)
          caching_enabled = !@opts[:no_cache] && (workspace || @opts[:cache])
          return nil unless caching_enabled

          Nokizaru::CacheStore.new(workspace ? workspace.cache_dir : Paths.cache_dir)
        end

        def initial_run_payload(target, info, start_time)
          {
            'meta' => run_meta_payload(target, info, start_time),
            'modules' => {},
            'artifacts' => {},
            'findings' => []
          }
        end

        def run_meta_payload(target, info, start_time)
          {
            'version' => Nokizaru::VERSION,
            'target' => target,
            'hostname' => info[:hostname],
            'ip' => info[:ip],
            'started_at' => start_time.utc.iso8601
          }
        end

        def initialize_workspace_run(workspace, run)
          return nil unless workspace

          run_id, = workspace.start_run(run['meta'])
          run['meta']['workspace'] = {
            'project' => workspace.project_name,
            'target' => workspace.target_host,
            'run_id' => run_id,
            'base_dir' => workspace.base_dir
          }
          UI.row(:info, 'Workspace enabled', workspace.base_dir)
          run_id
        end

        def finalize_run_timing(run, start_time)
          elapsed = Time.now - start_time
          run['meta']['ended_at'] = Time.now.utc.iso8601
          run['meta']['elapsed_s'] = elapsed
          elapsed
        end
      end
    end
  end
end
