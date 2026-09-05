# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
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
            "KEYS:#{Paths.keys_file}, CONFIG:#{Paths.config_file}, LOG:#{Paths.log_file}"
          )
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
