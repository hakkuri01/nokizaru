# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'timeout'

module Bench
  # Comprehensive benchmark suite with deterministic and live tracks
  module ComprehensiveSuite
    TRACKS = %w[track_a track_b].freeze

    DEFAULTS = {
      track: 'track_a',
      runs: nil,
      concurrency: 1,
      timeout_s: nil,
      root_dir: File.expand_path('../..', __dir__),
      out_dir: File.expand_path('../results/comprehensive', __dir__),
      nokizaru_bin: File.expand_path('../../bin/nokizaru', __dir__),
      skip_existing: false,
      fail_fast: false,
      dry_run: false,
      resource_metrics: true,
      write_baseline: false,
      rolling_window: 0,
      baseline_path: File.expand_path('../config/baselines/default.json', __dir__),
      strict: nil,
      targets_path: nil
    }.freeze

    TRACK_CONFIG = {
      'track_a' => {
        default_runs: 5,
        default_timeout_s: 300,
        default_strict: true,
        targets_path: File.expand_path('../config/track_a_targets.json', __dir__),
        thresholds: {
          median_runtime_regression_pct: 180.0,
          p95_runtime_regression_pct: 220.0,
          min_success_rate: 1.0,
          max_elapsed_cv: 0.3
        }
      },
      'track_b' => {
        default_runs: 2,
        default_timeout_s: 120,
        default_strict: false,
        targets_path: File.expand_path('../config/track_b_targets.json', __dir__),
        thresholds: {
          median_runtime_regression_pct: 80.0,
          p95_runtime_regression_pct: 110.0,
          min_success_rate: 0.75,
          max_elapsed_cv: 0.7
        }
      }
    }.freeze

    class CLI
      def self.run(argv)
        options = parse_options(argv)
        runner = Runner.new(options)
        runner.run
      rescue StandardError => e
        warn "[bench] fatal: #{e.class} #{e.message}"
        1
      end

      def self.parse_options(argv)
        opts = DEFAULTS.dup

        OptionParser.new do |parser|
          parser.banner = 'Usage: ruby bench/comprehensive_benchmark_suite.rb [options]'
          configure_parser(parser, opts)
        end.parse!(argv)

        opts
      end

      def self.configure_parser(parser, opts)
        parser.on('--track NAME', TRACKS, 'Benchmark track: track_a or track_b') { |value| opts[:track] = value }
        parser.on('--runs N', Integer, 'Runs per profile') { |value| opts[:runs] = [value.to_i, 1].max }
        parser.on('--concurrency N', Integer, 'Concurrent targets per run') do |value|
          opts[:concurrency] = value.to_i.clamp(1, 8)
        end
        parser.on('--timeout S', Integer, 'Per-command timeout in seconds') do |value|
          opts[:timeout_s] = [value.to_i, 30].max
        end
        parser.on('--out DIR', String, 'Output directory root') { |value| opts[:out_dir] = File.expand_path(value) }
        parser.on('--nokizaru PATH', String, 'Path to nokizaru executable') do |value|
          opts[:nokizaru_bin] = File.expand_path(value)
        end
        parser.on('--targets PATH', String, 'Override target config json path') do |value|
          opts[:targets_path] = File.expand_path(value)
        end
        parser.on('--baseline PATH', String, 'Baseline json path') do |value|
          opts[:baseline_path] = File.expand_path(value)
        end
        parser.on('--skip-existing', 'Skip job if output json exists') { opts[:skip_existing] = true }
        parser.on('--no-skip-existing', 'Always rerun all jobs') { opts[:skip_existing] = false }
        parser.on('--fail-fast', 'Stop queue after first failed job') { opts[:fail_fast] = true }
        parser.on('--strict', 'Force strict pass/fail behavior') { opts[:strict] = true }
        parser.on('--no-strict', 'Force non-strict warning behavior') { opts[:strict] = false }
        parser.on('--dry-run', 'Print planned commands and exit') { opts[:dry_run] = true }
        parser.on('--resource-metrics', 'Capture cpu/rss using /usr/bin/time') { opts[:resource_metrics] = true }
        parser.on('--no-resource-metrics', 'Disable cpu/rss collection') { opts[:resource_metrics] = false }
        parser.on('--write-baseline', 'Write current medians/p95 into baseline file') { opts[:write_baseline] = true }
        parser.on('--rolling-window N', Integer,
                  'Use rolling baseline from last N manifests for this track') do |value|
          opts[:rolling_window] = [value.to_i, 0].max
        end
      end
    end

    class Runner
      def initialize(options)
        @options = hydrate_defaults(options)
        @results = []
        @result_mutex = Mutex.new
      end

      def run
        ensure_paths!
        targets = load_targets
        jobs = build_jobs(targets)
        puts "[bench] track=#{@options[:track]} profiles=#{targets.length} jobs=#{jobs.length}"

        return dry_run(jobs) if @options[:dry_run]

        execute_jobs(jobs)
        manifest = build_manifest(targets)
        baseline_written = write_baseline_snapshot(manifest)
        manifest_path = write_manifest(manifest)
        summary_path = write_summary(manifest)
        print_summary(manifest, manifest_path, summary_path, baseline_written)
        manifest.fetch('verdict', {}).fetch('exit_code', 0)
      end

      private

      def hydrate_defaults(options)
        track = options[:track] || DEFAULTS[:track]
        track_cfg = TRACK_CONFIG.fetch(track)
        output_root = File.expand_path(File.join(options[:out_dir], track))
        {
          track: track,
          runs: options[:runs] || track_cfg[:default_runs],
          concurrency: options[:concurrency],
          timeout_s: options[:timeout_s] || track_cfg[:default_timeout_s],
          root_dir: options[:root_dir],
          out_dir: output_root,
          nokizaru_bin: options[:nokizaru_bin],
          skip_existing: options[:skip_existing],
          fail_fast: options[:fail_fast],
          dry_run: options[:dry_run],
          resource_metrics: options[:resource_metrics],
          write_baseline: options[:write_baseline],
          rolling_window: options[:rolling_window],
          baseline_path: options[:baseline_path],
          strict: options[:strict].nil? ? track_cfg[:default_strict] : options[:strict],
          targets_path: options[:targets_path] || track_cfg[:targets_path],
          thresholds: track_cfg[:thresholds]
        }
      end

      def ensure_paths!
        FileUtils.mkdir_p(@options[:out_dir])
        FileUtils.mkdir_p(log_dir)
        raise "nokizaru executable not found: #{@options[:nokizaru_bin]}" unless File.exist?(@options[:nokizaru_bin])

        return if File.exist?(@options[:targets_path])

        raise "targets config not found: #{@options[:targets_path]}"
      end

      def load_targets
        payload = JSON.parse(File.read(@options[:targets_path]))
        targets = Array(payload['targets'])
        raise 'target config has no targets entries' if targets.empty?

        targets.map { |row| normalize_target_row(row) }
      end

      def normalize_target_row(row)
        id = row.fetch('id').to_s.strip
        url = row.fetch('url').to_s.strip
        args = Array(row['args']).map(&:to_s).map(&:strip).reject(&:empty?)
        quality_floors = row['quality_floors'].is_a?(Hash) ? row['quality_floors'] : {}
        threshold_overrides = row['threshold_overrides'].is_a?(Hash) ? row['threshold_overrides'] : {}
        raise 'target id is required' if id.empty?
        raise "target url is required for #{id}" if url.empty?

        {
          id: id,
          url: url,
          args: args,
          timeout_s: row['timeout_s'].to_i.positive? ? row['timeout_s'].to_i : nil,
          quality_floors: quality_floors,
          threshold_overrides: threshold_overrides,
          notes: row['notes'].to_s
        }
      end

      def build_jobs(targets)
        jobs = []
        (1..@options[:runs]).each do |run_index|
          targets.each do |target|
            basename = "#{@options[:track]}_r#{run_index}_#{target[:id]}"
            output_path = File.join(@options[:out_dir], "#{basename}.json")
            next if @options[:skip_existing] && File.exist?(output_path)

            jobs << {
              run: run_index,
              target: target,
              basename: basename,
              output_path: output_path,
              log_path: File.join(log_dir, "#{basename}.log"),
              timeout_s: target[:timeout_s] || @options[:timeout_s]
            }
          end
        end
        jobs
      end

      def write_baseline_snapshot(manifest)
        return nil unless @options[:write_baseline]

        snapshot = Baseline.snapshot_from_profiles(manifest.fetch('profiles', {}))
        Baseline.write(@options[:baseline_path], @options[:track], snapshot)
      end

      def dry_run(jobs)
        jobs.each do |job|
          puts "[dry-run] #{build_command(job).join(' ')}"
        end
        0
      end

      def execute_jobs(jobs)
        queue = Queue.new
        jobs.each { |job| queue << job }
        workers = Array.new(@options[:concurrency]) { |index| Thread.new { worker_loop(queue, index + 1) } }
        workers.each(&:join)
      end

      def worker_loop(queue, worker_id)
        loop do
          job = queue.pop(true)
          break unless job

          result = run_job(job, worker_id)
          @result_mutex.synchronize { @results << result }
          next unless @options[:fail_fast]
          next if result[:status] == 'ok'

          drain_queue!(queue)
          break
        rescue ThreadError
          break
        end
      end

      def run_job(job, worker_id)
        cleanup_previous_outputs(job)
        command = build_command(job)
        wrapped_command = command_for_execution(command)
        started_at = Time.now.utc
        start_t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        puts "[bench][w#{worker_id}] run=#{job[:run]} profile=#{job[:target][:id]}"

        output, status, timed_out, resources = run_command_with_timeout(wrapped_command, job[:timeout_s])
        File.write(job[:log_path], output)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_t
        ok = status&.success? && File.exist?(job[:output_path])
        final_status = if ok
                         'ok'
                       else
                         (timed_out ? 'timeout' : 'failed')
                       end
        metrics = ok ? Metrics.extract(job[:output_path]) : {}
        floor_result = FloorCheck.check(metrics, job[:target][:quality_floors])

        {
          run: job[:run],
          track: @options[:track],
          profile_id: job[:target][:id],
          target_url: job[:target][:url],
          command: command,
          timeout_s: job[:timeout_s],
          status: final_status,
          timed_out: timed_out,
          exit_code: status&.exitstatus,
          elapsed_s: elapsed.round(4),
          output_path: job[:output_path],
          log_path: job[:log_path],
          started_at: started_at.iso8601,
          ended_at: Time.now.utc.iso8601,
          metrics: metrics,
          quality_floors: floor_result,
          resources: resources
        }
      end

      def command_for_execution(command)
        return command unless @options[:resource_metrics]
        return command unless File.executable?('/usr/bin/time')

        ['/usr/bin/time', '-f', ResourceMetrics::FORMAT, *command]
      end

      def build_command(job)
        args = [
          RbConfig.ruby,
          @options[:nokizaru_bin],
          '--target',
          job[:target][:url]
        ]
        args.concat(job[:target][:args])
        args.push(
          '--export',
          '--no-cache',
          '-o',
          'json',
          '--cd',
          @options[:out_dir],
          '--of',
          job[:basename],
          '-nb'
        )
        args
      end

      def cleanup_previous_outputs(job)
        FileUtils.rm_f(job[:output_path])
        FileUtils.rm_f(job[:log_path])
      end

      def run_command_with_timeout(command, timeout_s)
        output = +''
        status = nil
        timed_out = false

        Open3.popen2e(*command) do |stdin, io, wait_thr|
          stdin.close
          pid = wait_thr.pid
          begin
            Timeout.timeout(timeout_s) do
              io.each_line { |line| output << line }
              status = wait_thr.value
            end
          rescue Timeout::Error
            timed_out = true
            terminate_process(pid)
          ensure
            io.close
          end
        end

        cleaned_output, resources = ResourceMetrics.extract(output)
        [cleaned_output, status, timed_out, resources]
      rescue StandardError => e
        ["runner exception: #{e.class} #{e.message}\n", nil, false, {}]
      end

      def terminate_process(pid)
        Process.kill('TERM', pid)
        sleep(0.5)
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end

      def drain_queue!(queue)
        loop { queue.pop(true) }
      rescue ThreadError
        nil
      end

      def build_manifest(targets)
        grouped = Aggregate.by_profile(@results, targets)
        baseline, baseline_meta = resolve_baseline
        verdict = Verdict.evaluate(
          grouped,
          baseline,
          thresholds: @options[:thresholds],
          strict: @options[:strict]
        )

        {
          'generated_at' => Time.now.utc.iso8601,
          'version' => 1,
          'config' => {
            'track' => @options[:track],
            'runs' => @options[:runs],
            'concurrency' => @options[:concurrency],
            'timeout_s' => @options[:timeout_s],
            'out_dir' => @options[:out_dir],
            'nokizaru_bin' => @options[:nokizaru_bin],
            'targets_path' => @options[:targets_path],
            'baseline_path' => @options[:baseline_path],
            'strict' => @options[:strict],
            'resource_metrics' => @options[:resource_metrics],
            'write_baseline' => @options[:write_baseline],
            'rolling_window' => @options[:rolling_window],
            'baseline_source' => baseline_meta[:source],
            'baseline_sample_manifests' => baseline_meta[:sample_count]
          },
          'results' => @results.sort_by { |row| [row[:run], row[:profile_id]] },
          'profiles' => grouped,
          'verdict' => verdict
        }
      end

      def resolve_baseline
        rolling = RollingBaseline.load(
          out_dir: @options[:out_dir],
          track: @options[:track],
          window: @options[:rolling_window]
        )
        if rolling[:sample_count].positive?
          return [rolling[:baseline],
                  { source: 'rolling', sample_count: rolling[:sample_count] }]
        end

        static = Baseline.load(@options[:baseline_path], @options[:track])
        [static, { source: 'file', sample_count: 0 }]
      end

      def write_manifest(manifest)
        path = File.join(
          @options[:out_dir],
          "#{@options[:track]}_manifest_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json"
        )
        File.write(path, JSON.pretty_generate(manifest))
        path
      end

      def write_summary(manifest)
        path = File.join(
          @options[:out_dir],
          "#{@options[:track]}_summary_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.md"
        )
        File.write(path, Summary.markdown(manifest))
        path
      end

      def print_summary(manifest, manifest_path, summary_path, baseline_written)
        verdict = manifest.fetch('verdict', {})
        puts "[bench] track=#{@options[:track]} strict=#{@options[:strict]}"
        puts "[bench] pass=#{verdict.fetch('passed_profiles',
                                           0)} warn=#{verdict.fetch('warning_profiles',
                                                                    0)} fail=#{verdict.fetch('failed_profiles', 0)}"
        puts "[bench] manifest=#{manifest_path}"
        puts "[bench] summary=#{summary_path}"
        puts "[bench] baseline_updated=#{baseline_written}" if baseline_written
      end

      def log_dir
        File.join(@options[:out_dir], 'logs')
      end
    end

    module Metrics
      module_function

      def extract(json_path)
        payload = JSON.parse(File.read(json_path))
        modules = payload.fetch('modules', {})

        {
          elapsed_s: payload.dig('meta', 'elapsed_s').to_f,
          findings_count: Array(payload['findings']).length,
          directory_requests_per_second: modules.dig('directory_enum', 'stats', 'requests_per_second').to_f,
          directory_total_requests: modules.dig('directory_enum', 'stats', 'total_requests').to_i,
          directory_errors: modules.dig('directory_enum', 'stats', 'errors').to_i,
          directory_mode: modules.dig('directory_enum', 'stats', 'mode').to_s,
          directory_found_count: Array(modules.dig('directory_enum', 'found')).length,
          directory_prioritized_count: Array(modules.dig('directory_enum', 'prioritized_found')).length,
          crawler_total_unique: modules.dig('crawler', 'stats', 'total_unique').to_i,
          crawler_high_signal_count: modules.dig('crawler', 'stats', 'high_signal_count').to_i,
          subdomains_count: Array(modules.dig('subdomains', 'subdomains')).length,
          open_ports_count: Array(modules.dig('portscan', 'open_ports')).length,
          wayback_url_count: Array(modules.dig('wayback', 'urls')).length,
          wayback_cdx_status: modules.dig('wayback', 'cdx_status').to_s
        }
      rescue StandardError
        {}
      end
    end

    module ResourceMetrics
      module_function

      FORMAT = '__NK_TIME__ RSS_KB=%M USER_S=%U SYS_S=%S'

      def extract(output)
        lines = output.to_s.lines
        marker = lines.find { |line| line.include?('__NK_TIME__') }
        return [output.to_s, {}] unless marker

        cleaned = lines.reject { |line| line.include?('__NK_TIME__') }.join
        [cleaned, parse_marker(marker)]
      end

      def parse_marker(marker)
        {
          'max_rss_kb' => marker[/RSS_KB=(\d+)/, 1].to_i,
          'cpu_user_s' => marker[/USER_S=([0-9.]+)/, 1].to_f,
          'cpu_system_s' => marker[/SYS_S=([0-9.]+)/, 1].to_f
        }
      rescue StandardError
        {}
      end
    end

    module FloorCheck
      module_function

      def check(metrics, floors)
        expected = stringify_keys(floors)
        checks = expected.each_with_object({}) do |(key, floor), out|
          value = metrics[key.to_sym]
          out[key] = {
            'expected_min' => floor,
            'actual' => numeric_value(value),
            'passed' => numeric_value(value) >= floor.to_f
          }
        end

        {
          'checks' => checks,
          'passed' => checks.values.all? { |item| item['passed'] }
        }
      end

      def stringify_keys(hash)
        Hash(hash || {}).transform_keys(&:to_s)
      end

      def numeric_value(value)
        value.nil? ? 0.0 : value.to_f
      end
    end

    module Aggregate
      module_function

      def by_profile(results, targets)
        target_map = targets.each_with_object({}) { |row, out| out[row[:id]] = row }
        grouped_runs = results.group_by { |row| row[:profile_id] }
        grouped_runs.keys.sort.each_with_object({}) do |profile_id, out|
          runs = grouped_runs[profile_id]
          out[profile_id] = profile_payload(profile_id, runs, target_map[profile_id])
        end
      end

      def profile_payload(profile_id, runs, target)
        successful = runs.select { |row| row[:status] == 'ok' }
        elapsed = successful.map { |row| row[:metrics][:elapsed_s].to_f }
        {
          'profile_id' => profile_id,
          'target_url' => target&.dig(:url),
          'threshold_overrides' => target&.dig(:threshold_overrides) || {},
          'runs' => runs.length,
          'successful_runs' => successful.length,
          'success_rate' => rate(successful.length, runs.length),
          'elapsed_median_s' => Stats.median(elapsed),
          'elapsed_p95_s' => Stats.p95(elapsed),
          'elapsed_cv' => Stats.coefficient_of_variation(elapsed),
          'directory_rps_median' => Stats.median(metric_series(successful, :directory_requests_per_second)),
          'crawler_unique_median' => Stats.median(metric_series(successful, :crawler_total_unique)),
          'subdomains_median' => Stats.median(metric_series(successful, :subdomains_count)),
          'rss_kb_median' => Stats.median(resource_series(successful, 'max_rss_kb')),
          'cpu_user_s_median' => Stats.median(resource_series(successful, 'cpu_user_s')),
          'cpu_system_s_median' => Stats.median(resource_series(successful, 'cpu_system_s')),
          'floor_pass_rate' => floor_pass_rate(runs)
        }
      end

      def metric_series(rows, key)
        rows.map { |row| row.dig(:metrics, key).to_f }
      end

      def resource_series(rows, key)
        rows.map { |row| row.dig(:resources, key).to_f }
      end

      def floor_pass_rate(rows)
        total = rows.length
        return 0.0 if total.zero?

        passed = rows.count { |row| row.dig(:quality_floors, 'passed') }
        rate(passed, total)
      end

      def rate(numerator, denominator)
        return 0.0 if denominator.to_i <= 0

        (numerator.to_f / denominator).round(4)
      end
    end

    module Stats
      module_function

      def median(values)
        nums = compact_numeric(values)
        return 0.0 if nums.empty?

        sorted = nums.sort
        mid = sorted.length / 2
        return sorted[mid].round(4) if sorted.length.odd?

        ((sorted[mid - 1] + sorted[mid]) / 2.0).round(4)
      end

      def p95(values)
        nums = compact_numeric(values)
        return 0.0 if nums.empty?

        sorted = nums.sort
        idx = [(sorted.length * 0.95).ceil - 1, 0].max
        sorted[idx].round(4)
      end

      def compact_numeric(values)
        Array(values).map(&:to_f).reject(&:nan?)
      end

      def coefficient_of_variation(values)
        nums = compact_numeric(values)
        return 0.0 if nums.length <= 1

        mean = nums.sum / nums.length.to_f
        return 0.0 if mean <= 0.0

        variance = nums.sum { |value| (value - mean)**2 } / nums.length.to_f
        Math.sqrt(variance).fdiv(mean).round(4)
      end
    end

    module Baseline
      module_function

      def load(path, track)
        return {} unless File.exist?(path)

        payload = JSON.parse(File.read(path))
        payload.fetch(track, {})
      rescue StandardError
        {}
      end

      def snapshot_from_profiles(profiles)
        profiles.transform_values do |row|
          {
            'elapsed_median_s' => row['elapsed_median_s'].to_f.round(4),
            'elapsed_p95_s' => row['elapsed_p95_s'].to_f.round(4)
          }
        end
      end

      def write(path, track, snapshot)
        payload = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        payload[track] = snapshot
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(payload))
        path
      rescue StandardError
        nil
      end
    end

    module RollingBaseline
      module_function

      def load(out_dir:, track:, window:)
        limit = window.to_i
        return { baseline: {}, sample_count: 0 } if limit <= 0

        manifests = recent_manifests(out_dir, track, limit)
        return { baseline: {}, sample_count: 0 } if manifests.empty?

        { baseline: aggregate(manifests), sample_count: manifests.length }
      end

      def recent_manifests(out_dir, track, limit)
        pattern = File.join(out_dir, "#{track}_manifest_*.json")
        Dir[pattern].last(limit)
      end

      def aggregate(paths)
        series = Hash.new { |hash, key| hash[key] = { medians: [], p95s: [] } }

        paths.each do |path|
          payload = JSON.parse(File.read(path))
          profiles = payload.fetch('profiles', {})
          profiles.each do |profile_id, row|
            series[profile_id][:medians] << row['elapsed_median_s'].to_f
            series[profile_id][:p95s] << row['elapsed_p95_s'].to_f
          end
        end

        series.transform_values do |values|
          {
            'elapsed_median_s' => Stats.median(values[:medians]),
            'elapsed_p95_s' => Stats.median(values[:p95s])
          }
        end
      rescue StandardError
        {}
      end
    end

    module Verdict
      module_function

      def evaluate(profiles, baseline, thresholds:, strict:)
        rows = profiles.each_with_object({}) do |(profile_id, metrics), out|
          out[profile_id] = evaluate_profile(profile_id, metrics, baseline[profile_id], thresholds, strict)
        end

        counts = count_statuses(rows)
        exit_code = strict && counts[:fail].positive? ? 2 : 0
        {
          'strict' => strict,
          'profiles' => rows,
          'passed_profiles' => counts[:pass],
          'warning_profiles' => counts[:warn],
          'failed_profiles' => counts[:fail],
          'exit_code' => exit_code
        }
      end

      def evaluate_profile(profile_id, metrics, baseline_metrics, thresholds, strict)
        effective_thresholds = thresholds_for_profile(thresholds, metrics)
        status = 'pass'
        reasons = []

        if metrics['success_rate'].to_f < effective_thresholds[:min_success_rate].to_f
          status = 'fail'
          reasons << format('success_rate %<actual>.2f below minimum %<expected>.2f',
                            actual: metrics['success_rate'], expected: effective_thresholds[:min_success_rate])
        end

        unless metrics['floor_pass_rate'].to_f >= 1.0
          status = 'fail'
          reasons << format('quality floors pass rate %.2f below 1.00', metrics['floor_pass_rate'])
        end

        max_cv = effective_thresholds[:max_elapsed_cv]
        if max_cv && metrics['elapsed_cv'].to_f > max_cv.to_f
          status = downgrade_status(status, strict)
          reasons << format('elapsed cv %<actual>.2f exceeds %<expected>.2f', actual: metrics['elapsed_cv'],
                                                                              expected: max_cv)
        end

        return no_baseline_result(profile_id, status, reasons) unless baseline_metrics.is_a?(Hash)

        median_delta = regression_pct(metrics['elapsed_median_s'], baseline_metrics['elapsed_median_s'])
        p95_delta = regression_pct(metrics['elapsed_p95_s'], baseline_metrics['elapsed_p95_s'])

        if median_delta > effective_thresholds[:median_runtime_regression_pct].to_f
          status = downgrade_status(status, strict)
          reasons << format('median runtime regression %<actual>.2f%% exceeds %<expected>.2f%%',
                            actual: median_delta, expected: effective_thresholds[:median_runtime_regression_pct])
        end

        if p95_delta > effective_thresholds[:p95_runtime_regression_pct].to_f
          status = downgrade_status(status, strict)
          reasons << format('p95 runtime regression %<actual>.2f%% exceeds %<expected>.2f%%',
                            actual: p95_delta, expected: effective_thresholds[:p95_runtime_regression_pct])
        end

        {
          'profile_id' => profile_id,
          'status' => status,
          'reasons' => reasons,
          'baseline' => baseline_metrics,
          'regression_pct' => {
            'elapsed_median_s' => median_delta.round(4),
            'elapsed_p95_s' => p95_delta.round(4)
          }
        }
      end

      def thresholds_for_profile(defaults, metrics)
        merged = defaults.dup
        overrides = metrics['threshold_overrides'].is_a?(Hash) ? metrics['threshold_overrides'] : {}
        overrides.each do |key, value|
          symbol = key.to_sym
          next unless merged.key?(symbol)

          merged[symbol] = value
        end
        merged
      end

      def no_baseline_result(profile_id, current_status, reasons)
        status = current_status == 'fail' ? 'fail' : 'warn'
        {
          'profile_id' => profile_id,
          'status' => status,
          'reasons' => reasons + ['no baseline available'],
          'baseline' => nil,
          'regression_pct' => {
            'elapsed_median_s' => 0.0,
            'elapsed_p95_s' => 0.0
          }
        }
      end

      def downgrade_status(current_status, strict)
        return 'fail' if current_status == 'fail'

        strict ? 'fail' : 'warn'
      end

      def regression_pct(current, baseline)
        base = baseline.to_f
        return 0.0 if base <= 0.0

        ((current.to_f - base) / base) * 100.0
      end

      def count_statuses(rows)
        rows.values.each_with_object({ pass: 0, warn: 0, fail: 0 }) do |item, out|
          case item['status']
          when 'pass' then out[:pass] += 1
          when 'warn' then out[:warn] += 1
          else out[:fail] += 1
          end
        end
      end
    end

    module Summary
      module_function

      def markdown(manifest)
        profiles = manifest.fetch('profiles', {})
        verdicts = manifest.fetch('verdict', {}).fetch('profiles', {})

        lines = []
        lines << "# Comprehensive Benchmark Summary (#{manifest.dig('config', 'track')})"
        lines <<
          "Generated: #{manifest['generated_at']} | Strict: #{manifest.dig('config',
                                                                           'strict')} | Runs: #{manifest.dig('config',
                                                                                                             'runs')}"
        lines <<
          '| Profile | Success Rate | Median (s) | p95 (s) | CV | Dir RPS | RSS KB | Floor Pass | Verdict | Notes |'
        lines <<
          '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |'

        profiles.keys.sort.each do |profile_id|
          row = profiles.fetch(profile_id)
          verdict = verdicts.fetch(profile_id, {})
          notes = Array(verdict['reasons']).join('; ')
          lines << [
            profile_id,
            format('%.2f', row['success_rate'].to_f),
            format('%.2f', row['elapsed_median_s'].to_f),
            format('%.2f', row['elapsed_p95_s'].to_f),
            format('%.2f', row['elapsed_cv'].to_f),
            format('%.1f', row['directory_rps_median'].to_f),
            format('%.0f', row['rss_kb_median'].to_f),
            format('%.2f', row['floor_pass_rate'].to_f),
            verdict.fetch('status', 'n/a'),
            notes.empty? ? '-' : notes
          ].join(' | ').prepend('| ').concat(' |')
        end

        lines << ''
        lines << format('Verdict: pass=%<pass>d warn=%<warn>d fail=%<fail>d',
                        pass: manifest.dig('verdict', 'passed_profiles').to_i,
                        warn: manifest.dig('verdict', 'warning_profiles').to_i,
                        fail: manifest.dig('verdict', 'failed_profiles').to_i)
        lines.join("\n")
      end
    end
  end
end
