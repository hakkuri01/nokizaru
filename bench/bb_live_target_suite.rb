#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'timeout'
require 'uri'

class BBLiveTargetSuite
  TARGETS = [
    'https://demo.owasp-juice.shop',
    'https://httpbin.org',
    'http://scanme.nmap.org',
    'http://portquiz.net',
    'https://badssl.com',
    'https://httpstat.us',
    'https://zonetransfer.me',
    'https://github.com',
    'https://wikipedia.org',
    'https://developer.mozilla.org',
    'https://verizon.com',
    'https://google.com',
    'https://instagram.com',
    'https://gitlab.com',
    'https://valvesoftware.com',
    'https://netflix.com',
    'https://proton.me',
    'https://shopify.com',
    'https://mastodon.social',
    'https://hoyoverse.com',
    'https://openai.com',
    'https://amazon.com',
    'https://cloudflare.com',
    'https://riotgames.com'
  ].freeze

  PROFILE_CONFIG = {
    'canonical' => {
      no_cache: true,
      default_timeout: 420,
      min_timeout: 90,
      max_timeout: 600,
      thresholds: {
        median_runtime_regression_pct: 30.0,
        p95_runtime_regression_pct: 40.0,
        min_success_rate: 0.9,
        max_elapsed_cv: 0.6
      }
    },
    'fast' => {
      no_cache: false,
      default_timeout: 240,
      min_timeout: 60,
      max_timeout: 360,
      thresholds: {
        median_runtime_regression_pct: 35.0,
        p95_runtime_regression_pct: 45.0,
        min_success_rate: 0.85,
        max_elapsed_cv: 0.8
      }
    }
  }.freeze

  DEFAULTS = {
    runs: 1,
    concurrency: 1,
    timeout_s: nil,
    out_dir: File.expand_path('results/bb_live_targets', __dir__),
    nokizaru_bin: File.expand_path('../bin/nokizaru', __dir__),
    skip_existing: true,
    fail_fast: false,
    dry_run: false,
    include_targets: nil,
    strict: nil,
    resource_metrics: true,
    write_baseline: false,
    rolling_window: 0,
    shard_count: 1,
    shard_index: 0,
    profile: 'canonical',
    baseline_path: File.expand_path('config/baselines/bb_live_target_suite.json', __dir__)
  }.freeze

  class << self
    def target_key(url)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase
      host.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
    rescue URI::InvalidURIError
      url.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
    end

    def build_command(nokizaru_bin:, target:, out_dir:, basename:, no_cache: true)
      args = [
        RbConfig.ruby,
        nokizaru_bin,
        '--url',
        target,
        '--full',
        '--export'
      ]
      args << '--no-cache' if no_cache
      args.concat([
                    '-o',
                    'json',
                    '--cd',
                    out_dir,
                    '--of',
                    basename,
                    '-nb'
                  ])
      args
    end

    def shard_targets(targets, shard_count, shard_index)
      return Array(targets) if shard_count.to_i <= 1

      sorted = Array(targets).sort_by { |target| target_key(target) }
      sorted.each_with_index.filter_map do |target, idx|
        target if (idx % shard_count.to_i) == shard_index.to_i
      end
    end

    def adaptive_timeout_for(target_key, profile_cfg, baseline, fallback)
      baseline_row = baseline[target_key]
      return fallback if baseline_row.nil?

      p95 = baseline_row['elapsed_p95_s'].to_f
      return fallback if p95 <= 0

      scaled = (p95 * 1.75).ceil
      scaled.clamp(profile_cfg[:min_timeout], profile_cfg[:max_timeout])
    end
  end

  def initialize(opts)
    @opts = hydrate_defaults(opts)
    @results = []
    @result_mutex = Mutex.new
  end

  def run
    ensure_paths!
    jobs = build_jobs
    puts "[bench] profile=#{@opts[:profile]} shard=#{@opts[:shard_index]}/#{@opts[:shard_count]} queued=#{jobs.length}"

    return print_planned_jobs(jobs) if @opts[:dry_run]

    execute_jobs(jobs)
    manifest = build_manifest
    baseline_written = write_baseline_snapshot(manifest)
    manifest_path = write_manifest(manifest)
    summary_path = write_summary(manifest)
    print_summary(manifest, manifest_path, summary_path, baseline_written)
    manifest.dig('verdict', 'exit_code').to_i
  end

  private

  def hydrate_defaults(opts)
    profile = opts[:profile] || DEFAULTS[:profile]
    profile_cfg = PROFILE_CONFIG.fetch(profile)
    strict_default = (profile == 'canonical')
    timeout_s = opts[:timeout_s] || profile_cfg[:default_timeout]

    DEFAULTS.merge(opts).merge(
      profile: profile,
      timeout_s: timeout_s,
      strict: opts[:strict].nil? ? strict_default : opts[:strict],
      thresholds: profile_cfg[:thresholds],
      no_cache: profile_cfg[:no_cache]
    )
  end

  def ensure_paths!
    FileUtils.mkdir_p(@opts[:out_dir])
    FileUtils.mkdir_p(log_dir)
    raise "nokizaru executable not found: #{@opts[:nokizaru_bin]}" unless File.exist?(@opts[:nokizaru_bin])
    return if @opts[:shard_count].to_i >= 1 && @opts[:shard_index].to_i.between?(0, @opts[:shard_count].to_i - 1)

    raise 'invalid shard parameters'
  end

  def build_jobs
    targets = selected_targets
    baseline, = resolve_baseline
    jobs = []

    (1..@opts[:runs]).each do |run_index|
      targets.each do |target|
        key = self.class.target_key(target)
        basename = "bb_#{@opts[:profile]}_r#{run_index}_#{key}"
        json_path = File.join(@opts[:out_dir], "#{basename}.json")
        next if @opts[:skip_existing] && File.exist?(json_path)

        timeout_s = self.class.adaptive_timeout_for(
          key,
          PROFILE_CONFIG.fetch(@opts[:profile]),
          baseline,
          @opts[:timeout_s].to_i
        )

        jobs << {
          run: run_index,
          target: target,
          target_key: key,
          basename: basename,
          json_path: json_path,
          log_path: File.join(log_dir, "#{basename}.log"),
          timeout_s: timeout_s
        }
      end
    end

    jobs
  end

  def selected_targets
    configured = @opts[:include_targets]
    targets = if configured.nil? || configured.empty?
                TARGETS
              else
                selected = TARGETS.select { |target| configured.include?(self.class.target_key(target)) }
                missing = configured - selected.map { |target| self.class.target_key(target) }
                warn "[bench] warning: unknown targets ignored: #{missing.join(', ')}" unless missing.empty?
                selected
              end

    deduped = dedupe_by_target_key(targets)
    self.class.shard_targets(deduped, @opts[:shard_count], @opts[:shard_index])
  end

  def dedupe_by_target_key(targets)
    seen = {}
    Array(targets).each_with_object([]) do |target, out|
      key = self.class.target_key(target)
      next if seen[key]

      seen[key] = true
      out << target
    end
  end

  def print_planned_jobs(jobs)
    jobs.each do |job|
      command = build_command(job)
      puts "[dry-run][timeout=#{job[:timeout_s]}s] #{command.join(' ')}"
    end
    0
  end

  def execute_jobs(jobs)
    queue = Queue.new
    jobs.each { |job| queue << job }

    workers = Array.new(@opts[:concurrency]) do |worker_index|
      Thread.new { run_worker(queue, worker_index + 1) }
    end
    workers.each(&:join)
  end

  def run_worker(queue, worker_id)
    loop do
      job = queue.pop(true)
      break unless job

      result = run_job(job, worker_id)
      @result_mutex.synchronize { @results << result }

      next unless @opts[:fail_fast]
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
    start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "[bench][w#{worker_id}] run=#{job[:run]} target=#{job[:target]} timeout=#{job[:timeout_s]}s"

    output, status, timed_out, resources = run_command_with_timeout(wrapped_command, job[:timeout_s])
    File.write(job[:log_path], output)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic
    success = status&.success? && File.exist?(job[:json_path])
    final_status = if success
                     'ok'
                   else
                     (timed_out ? 'timeout' : 'failed')
                   end

    puts "[bench][w#{worker_id}] #{job[:basename]} => #{final_status} (#{format('%.2f', elapsed)}s)"

    {
      run: job[:run],
      target: job[:target],
      target_key: job[:target_key],
      basename: job[:basename],
      json_path: job[:json_path],
      log_path: job[:log_path],
      command: command,
      timeout_s: job[:timeout_s],
      status: final_status,
      timed_out: timed_out,
      exit_code: status&.exitstatus,
      elapsed_s: elapsed.round(4),
      started_at: started_at.iso8601,
      ended_at: Time.now.utc.iso8601,
      resources: resources
    }
  end

  def build_command(job)
    self.class.build_command(
      nokizaru_bin: @opts[:nokizaru_bin],
      target: job[:target],
      out_dir: @opts[:out_dir],
      basename: job[:basename],
      no_cache: @opts[:no_cache]
    )
  end

  def command_for_execution(command)
    return command unless @opts[:resource_metrics]
    return command unless File.executable?('/usr/bin/time')

    ['/usr/bin/time', '-f', ResourceMetrics::FORMAT, *command]
  end

  def cleanup_previous_outputs(job)
    FileUtils.rm_f(job[:json_path])
    FileUtils.rm_f(job[:log_path])
  end

  def run_command_with_timeout(command, timeout_s)
    output = +''
    status = nil
    timed_out = false

    Open3.popen2e(*command) do |stdin, stdout_and_err, wait_thr|
      stdin.close
      pid = wait_thr.pid

      begin
        Timeout.timeout(timeout_s) do
          stdout_and_err.each_line { |line| output << line }
          status = wait_thr.value
        end
      rescue Timeout::Error
        timed_out = true
        terminate_process(pid)
      ensure
        stdout_and_err.close
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

  def build_manifest
    profiles = Aggregate.by_target(@results)
    baseline, baseline_meta = resolve_baseline
    verdict = Verdict.evaluate(
      profiles,
      baseline,
      thresholds: @opts[:thresholds],
      strict: @opts[:strict]
    )

    {
      'generated_at' => Time.now.utc.iso8601,
      'version' => 2,
      'config' => {
        'suite' => 'bb_live_target_suite',
        'profile' => @opts[:profile],
        'runs' => @opts[:runs],
        'concurrency' => @opts[:concurrency],
        'timeout_s' => @opts[:timeout_s],
        'out_dir' => @opts[:out_dir],
        'nokizaru_bin' => @opts[:nokizaru_bin],
        'skip_existing' => @opts[:skip_existing],
        'fail_fast' => @opts[:fail_fast],
        'strict' => @opts[:strict],
        'resource_metrics' => @opts[:resource_metrics],
        'write_baseline' => @opts[:write_baseline],
        'rolling_window' => @opts[:rolling_window],
        'shard_count' => @opts[:shard_count],
        'shard_index' => @opts[:shard_index],
        'baseline_path' => @opts[:baseline_path],
        'baseline_source' => baseline_meta[:source],
        'baseline_sample_manifests' => baseline_meta[:sample_count]
      },
      'results' => @results.sort_by { |row| [row[:run], row[:target_key]] },
      'targets' => profiles,
      'verdict' => verdict
    }
  end

  def resolve_baseline
    rolling = RollingBaseline.load(
      out_dir: @opts[:out_dir],
      profile: @opts[:profile],
      window: @opts[:rolling_window]
    )
    if rolling[:sample_count].positive?
      return [rolling[:baseline],
              { source: 'rolling', sample_count: rolling[:sample_count] }]
    end

    static = Baseline.load(@opts[:baseline_path], @opts[:profile])
    [static, { source: 'file', sample_count: 0 }]
  end

  def write_baseline_snapshot(manifest)
    return nil unless @opts[:write_baseline]

    snapshot = Baseline.snapshot_from_targets(manifest.fetch('targets', {}))
    Baseline.write(@opts[:baseline_path], @opts[:profile], snapshot)
  end

  def write_manifest(manifest)
    path = File.join(
      @opts[:out_dir],
      "bb_live_#{@opts[:profile]}_manifest_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json"
    )
    File.write(path, JSON.pretty_generate(manifest))
    path
  end

  def write_summary(manifest)
    path = File.join(
      @opts[:out_dir],
      "bb_live_#{@opts[:profile]}_summary_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.md"
    )
    File.write(path, Summary.markdown(manifest))
    path
  end

  def print_summary(manifest, manifest_path, summary_path, baseline_written)
    verdict = manifest.fetch('verdict', {})
    puts "[bench] profile=#{@opts[:profile]} strict=#{@opts[:strict]}"
    puts "[bench] pass=#{verdict.fetch('passed_targets',
                                       0)} warn=#{verdict.fetch('warning_targets',
                                                                0)} fail=#{verdict.fetch('failed_targets', 0)}"
    puts "[bench] manifest=#{manifest_path}"
    puts "[bench] summary=#{summary_path}"
    puts "[bench] baseline_updated=#{baseline_written}" if baseline_written
  end

  def log_dir
    File.join(@opts[:out_dir], 'logs')
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

    def coefficient_of_variation(values)
      nums = compact_numeric(values)
      return 0.0 if nums.length <= 1

      mean = nums.sum / nums.length.to_f
      return 0.0 if mean <= 0.0

      variance = nums.sum { |value| (value - mean)**2 } / nums.length.to_f
      Math.sqrt(variance).fdiv(mean).round(4)
    end

    def compact_numeric(values)
      Array(values).map(&:to_f).reject(&:nan?)
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

  module Aggregate
    module_function

    def by_target(results)
      grouped = results.group_by { |row| row[:target_key] }
      grouped.keys.sort.each_with_object({}) do |target_key, out|
        runs = grouped[target_key]
        successful = runs.select { |row| row[:status] == 'ok' }
        elapsed = successful.map { |row| row[:elapsed_s].to_f }

        out[target_key] = {
          'target_key' => target_key,
          'target' => runs.first[:target],
          'runs' => runs.length,
          'successful_runs' => successful.length,
          'success_rate' => rate(successful.length, runs.length),
          'elapsed_median_s' => Stats.median(elapsed),
          'elapsed_p95_s' => Stats.p95(elapsed),
          'elapsed_cv' => Stats.coefficient_of_variation(elapsed),
          'rss_kb_median' => Stats.median(successful.map { |row| row.dig(:resources, 'max_rss_kb').to_f }),
          'cpu_user_s_median' => Stats.median(successful.map { |row| row.dig(:resources, 'cpu_user_s').to_f }),
          'cpu_system_s_median' => Stats.median(successful.map { |row| row.dig(:resources, 'cpu_system_s').to_f })
        }
      end
    end

    def rate(numerator, denominator)
      return 0.0 if denominator.to_i <= 0

      (numerator.to_f / denominator.to_f).round(4)
    end
  end

  module Baseline
    module_function

    def load(path, profile)
      return {} unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      payload.fetch(profile, {})
    rescue StandardError
      {}
    end

    def snapshot_from_targets(targets)
      targets.each_with_object({}) do |(target_key, row), out|
        out[target_key] = {
          'elapsed_median_s' => row['elapsed_median_s'].to_f.round(4),
          'elapsed_p95_s' => row['elapsed_p95_s'].to_f.round(4)
        }
      end
    end

    def write(path, profile, snapshot)
      payload = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      payload[profile] = snapshot
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(payload))
      path
    rescue StandardError
      nil
    end
  end

  module RollingBaseline
    module_function

    def load(out_dir:, profile:, window:)
      limit = window.to_i
      return { baseline: {}, sample_count: 0 } if limit <= 0

      manifests = recent_manifests(out_dir, profile, limit)
      return { baseline: {}, sample_count: 0 } if manifests.empty?

      { baseline: aggregate(manifests), sample_count: manifests.length }
    end

    def recent_manifests(out_dir, profile, limit)
      pattern = File.join(out_dir, "bb_live_#{profile}_manifest_*.json")
      Dir[pattern].sort.last(limit)
    end

    def aggregate(paths)
      rows = Hash.new { |hash, key| hash[key] = { medians: [], p95s: [] } }
      paths.each do |path|
        payload = JSON.parse(File.read(path))
        payload.fetch('targets', {}).each do |target_key, row|
          rows[target_key][:medians] << row['elapsed_median_s'].to_f
          rows[target_key][:p95s] << row['elapsed_p95_s'].to_f
        end
      end

      rows.each_with_object({}) do |(target_key, values), out|
        out[target_key] = {
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

    def evaluate(targets, baseline, thresholds:, strict:)
      rows = targets.each_with_object({}) do |(target_key, metrics), out|
        out[target_key] = evaluate_target(target_key, metrics, baseline[target_key], thresholds, strict)
      end

      counts = count_statuses(rows)
      exit_code = strict && counts[:fail].positive? ? 2 : 0
      {
        'strict' => strict,
        'targets' => rows,
        'passed_targets' => counts[:pass],
        'warning_targets' => counts[:warn],
        'failed_targets' => counts[:fail],
        'exit_code' => exit_code
      }
    end

    def evaluate_target(target_key, metrics, baseline_row, thresholds, strict)
      status = 'pass'
      reasons = []

      if metrics['success_rate'].to_f < thresholds[:min_success_rate].to_f
        status = 'fail'
        reasons << format('success_rate %.2f below minimum %.2f', metrics['success_rate'],
                          thresholds[:min_success_rate])
      end

      if metrics['elapsed_cv'].to_f > thresholds[:max_elapsed_cv].to_f
        status = downgrade_status(status, strict)
        reasons << format('elapsed cv %.2f exceeds %.2f', metrics['elapsed_cv'], thresholds[:max_elapsed_cv])
      end

      unless baseline_row.is_a?(Hash)
        return {
          'target_key' => target_key,
          'status' => (status == 'fail' ? 'fail' : 'warn'),
          'reasons' => reasons + ['no baseline available'],
          'baseline' => nil,
          'regression_pct' => { 'elapsed_median_s' => 0.0, 'elapsed_p95_s' => 0.0 }
        }
      end

      median_delta = regression_pct(metrics['elapsed_median_s'], baseline_row['elapsed_median_s'])
      p95_delta = regression_pct(metrics['elapsed_p95_s'], baseline_row['elapsed_p95_s'])

      if median_delta > thresholds[:median_runtime_regression_pct].to_f
        status = downgrade_status(status, strict)
        reasons << format('median runtime regression %.2f%% exceeds %.2f%%', median_delta,
                          thresholds[:median_runtime_regression_pct])
      end

      if p95_delta > thresholds[:p95_runtime_regression_pct].to_f
        status = downgrade_status(status, strict)
        reasons << format('p95 runtime regression %.2f%% exceeds %.2f%%', p95_delta,
                          thresholds[:p95_runtime_regression_pct])
      end

      {
        'target_key' => target_key,
        'status' => status,
        'reasons' => reasons,
        'baseline' => baseline_row,
        'regression_pct' => {
          'elapsed_median_s' => median_delta.round(4),
          'elapsed_p95_s' => p95_delta.round(4)
        }
      }
    end

    def regression_pct(current, baseline)
      base = baseline.to_f
      return 0.0 if base <= 0.0

      ((current.to_f - base) / base) * 100.0
    end

    def downgrade_status(current_status, strict)
      return 'fail' if current_status == 'fail'

      strict ? 'fail' : 'warn'
    end

    def count_statuses(rows)
      rows.values.each_with_object({ pass: 0, warn: 0, fail: 0 }) do |row, out|
        case row['status']
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
      rows = manifest.fetch('targets', {})
      verdicts = manifest.dig('verdict', 'targets') || {}

      lines = []
      lines << "# BB Live Target Suite (#{manifest.dig('config', 'profile')})"
      lines << "Generated: #{manifest['generated_at']} | Strict: #{manifest.dig('config',
                                                                                'strict')} | Runs: #{manifest.dig(
                                                                                  'config', 'runs'
                                                                                )}"
      lines << '| Target | Success Rate | Median (s) | p95 (s) | CV | RSS KB | Verdict | Notes |'
      lines << '| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |'

      rows.keys.sort.each do |target_key|
        row = rows.fetch(target_key)
        verdict = verdicts.fetch(target_key, {})
        notes = Array(verdict['reasons']).join('; ')
        lines << [
          target_key,
          format('%.2f', row['success_rate'].to_f),
          format('%.2f', row['elapsed_median_s'].to_f),
          format('%.2f', row['elapsed_p95_s'].to_f),
          format('%.2f', row['elapsed_cv'].to_f),
          format('%.0f', row['rss_kb_median'].to_f),
          verdict.fetch('status', 'n/a'),
          notes.empty? ? '-' : notes
        ].join(' | ').prepend('| ').concat(' |')
      end

      lines << ''
      lines << "Verdict: pass=#{manifest.dig('verdict',
                                             'passed_targets')} warn=#{manifest.dig('verdict',
                                                                                    'warning_targets')} fail=#{manifest.dig(
                                                                                      'verdict', 'failed_targets'
                                                                                    )}"
      lines.join("\n")
    end
  end
end

def parse_options(argv)
  opts = BBLiveTargetSuite::DEFAULTS.dup

  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bench/bb_live_target_suite.rb [options]'

    parser.on('--profile NAME', %w[canonical fast], 'Execution profile (canonical or fast)') do |value|
      opts[:profile] = value
    end

    parser.on('--runs N', Integer, 'How many repetitions to run') do |value|
      opts[:runs] = [value.to_i, 1].max
    end

    parser.on('--concurrency N', Integer, 'Concurrent targets to run at once') do |value|
      opts[:concurrency] = value.to_i.clamp(1, 10)
    end

    parser.on('--timeout S', Integer, 'Fallback per-target timeout in seconds') do |value|
      opts[:timeout_s] = [value.to_i, 30].max
    end

    parser.on('--out DIR', String, 'Output directory for JSON and logs') do |value|
      opts[:out_dir] = File.expand_path(value)
    end

    parser.on('--nokizaru PATH', String, 'Path to nokizaru executable') do |value|
      opts[:nokizaru_bin] = File.expand_path(value)
    end

    parser.on('--targets x,y,z', Array, 'Target key subset (example: github_com,httpbin_org)') do |value|
      opts[:include_targets] = Array(value).map { |item| item.to_s.strip.downcase }.reject(&:empty?)
    end

    parser.on('--shard-count N', Integer, 'Total shard count for CI parallelization') do |value|
      opts[:shard_count] = [value.to_i, 1].max
    end

    parser.on('--shard-index N', Integer, 'Shard index for this runner (0-based)') do |value|
      opts[:shard_index] = [value.to_i, 0].max
    end

    parser.on('--baseline PATH', String, 'Baseline file path') do |value|
      opts[:baseline_path] = File.expand_path(value)
    end

    parser.on('--rolling-window N', Integer, 'Use last N manifests as rolling baseline') do |value|
      opts[:rolling_window] = [value.to_i, 0].max
    end

    parser.on('--write-baseline', 'Write medians/p95 from current run to baseline file') do
      opts[:write_baseline] = true
    end

    parser.on('--strict', 'Force strict pass/fail behavior') do
      opts[:strict] = true
    end

    parser.on('--no-strict', 'Force warning behavior for regressions') do
      opts[:strict] = false
    end

    parser.on('--resource-metrics', 'Capture cpu/rss with /usr/bin/time') do
      opts[:resource_metrics] = true
    end

    parser.on('--no-resource-metrics', 'Disable cpu/rss collection') do
      opts[:resource_metrics] = false
    end

    parser.on('--skip-existing', 'Skip runs when output JSON exists (default)') do
      opts[:skip_existing] = true
    end

    parser.on('--no-skip-existing', 'Always rerun even if output JSON exists') do
      opts[:skip_existing] = false
    end

    parser.on('--fail-fast', 'Stop remaining queue after first non-ok result') do
      opts[:fail_fast] = true
    end

    parser.on('--dry-run', 'Print generated commands and exit') do
      opts[:dry_run] = true
    end
  end.parse!(argv)

  opts
end

if $PROGRAM_NAME == __FILE__
  options = parse_options(ARGV)
  runner = BBLiveTargetSuite.new(options)
  exit(runner.run)
end
