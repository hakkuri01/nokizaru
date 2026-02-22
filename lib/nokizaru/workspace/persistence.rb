# frozen_string_literal: true

module Nokizaru
  class Workspace
    # File persistence helpers for workspace runs and metadata
    module Persistence
      def start_run(meta = {})
        run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(4)}"
        dir = run_dir(run_id)
        FileUtils.mkdir_p(dir)
        write_json_atomic(File.join(dir, 'meta.json'), (meta || {}).dup.merge('run_id' => run_id))
        [run_id, dir]
      end

      def run_dir(run_id)
        File.join(runs_dir, run_id.to_s)
      end

      def results_path(run_id)
        File.join(run_dir(run_id), 'results.json')
      end

      def save_run(run_id, run_hash)
        FileUtils.mkdir_p(run_dir(run_id))
        write_json_atomic(results_path(run_id), run_hash)
        results_path(run_id)
      end

      def load_run(run_id)
        JSON.parse(File.read(results_path(run_id)))
      end

      def run_ids
        return [] unless Dir.exist?(runs_dir)

        Dir.children(runs_dir).select { |name| File.directory?(File.join(runs_dir, name)) }.sort
      end

      def previous_run_id(current_run_id = nil)
        ids = run_ids
        return nil if ids.empty?

        return previous_known_run_id(ids, current_run_id) if current_run_id && ids.include?(current_run_id.to_s)

        ids[-2]
      end

      private

      def previous_known_run_id(ids, current_run_id)
        idx = ids.index(current_run_id.to_s)
        return nil if idx.nil? || idx.zero?

        ids[idx - 1]
      end

      def write_json_atomic(path, obj)
        FileUtils.mkdir_p(File.dirname(path))
        temp = Tempfile.new(['.nokizaru', '.json'], File.dirname(path))
        write_temp_json!(temp, obj)
        File.rename(temp.path, path)
      rescue StandardError
        cleanup_tempfile(temp)
        raise
      end

      def write_temp_json!(temp, obj)
        temp.binmode
        temp.write(JSON.pretty_generate(obj))
        temp.flush
        temp.fsync
        temp.close
      end

      def cleanup_tempfile(temp)
        return unless temp

        temp.close unless temp.closed?
        FileUtils.rm_f(temp.path)
      end
    end
  end
end
