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
    'https://riotgames.com',
    'https://microsoft.com',
    'https://adobe.com',
    'https://dropbox.com',
    'https://slack.com',
    'https://paypal.com',
    'https://stripe.com',
    'https://twilio.com',
    'https://uber.com',
    'https://airbnb.com',
    'https://coinbase.com',
    'https://reddit.com',
    'https://linkedin.com',
    'https://yahoo.com',
    'https://tiktok.com',
    'https://snapchat.com',
    'https://discord.com',
    'https://zoom.us',
    'https://epicgames.com',
    'https://spotify.com',
    'https://pinterest.com',
    'https://canva.com',
    'https://box.com',
    'https://intel.com',
    'https://mastercard.com',
    'https://hackthebox.com',
    'https://ecosia.org',
    'https://claude.ai',
    'https://apple.com',
    'https://oracle.com',
    'https://nvidia.com',
    'https://tesla.com',
    'https://okta.com',
    'https://cisco.com',
    'https://zendesk.com',
    'https://boeing.com',
    'https://yelp.com',
    'https://travelocity.com',
    'https://logitech.com',
    'https://arm.com',
    'https://motorola.com',
    'https://docusign.com',
    'https://info.credly.com',
    'https://coursera.org',
    'https://fedoraproject.org',
    'https://archlinux.org',
    'https://notion.com',
    'https://nike.com',
    'https://stockx.com',
    'https://soundcloud.com',
    'https://rakuten.com',
    'https://bosch.com',
    'https://booking.com',
    'https://wise.com',
    'https://mongodb.com',
    'https://salesforce.com',
    'https://snowflake.com',
    'https://asahi.com',
    'https://rakuten.co.jp',
    'https://line.me',
    'https://mercari.com',
    'https://dena.com',
    'https://gmo.jp',
    'https://sony.com',
    'https://panasonic.com',
    'https://toyota.jp',
    'https://nintendo.co.jp',
    'https://softbank.jp',
    'https://www.docomo.ne.jp',
    'https://global.fujitsu/ja-jp',
    'https://nec.com',
    'https://hitachi.com',
    'https://konami.com',
    'https://square-enix.com',
    'https://bandainamco.co.jp',
    'https://aniplex.co.jp',
    'https://cygames.co.jp',
    'https://animate.co.jp',
    'https://amiami.com',
    'https://kadokawa.co.jp',
    'https://yostar.co.jp',
    'https://goodsmile.com',
    'https://chat.sakana.ai'
  ].freeze

  STABLE_TARGET_KEYS = %w[
    httpbin_org
    badssl_com
    httpstat_us
    zonetransfer_me
    wikipedia_org
    gitlab_com
    cloudflare_com
    riotgames_com
    microsoft_com
    dropbox_com
    discord_com
    zoom_us
    canva_com
    box_com
    hackthebox_com
    claude_ai
    oracle_com
    boeing_com
    yelp_com
    docusign_com
    coursera_org
    fedoraproject_org
    archlinux_org
    notion_com
    stockx_com
    soundcloud_com
    mongodb_com
    salesforce_com
    line_me
    sony_com
    nintendo_co_jp
    hitachi_com
    konami_com
    square_enix_com
    goodsmile_com
  ].freeze

  TARGET_TIERS = {
    'stable' => STABLE_TARGET_KEYS,
    'full' => nil
  }.freeze

  PROFILE_CONFIG = {
    'canonical' => {
      no_cache: true,
      target_tier: 'stable',
      default_timeout: 420,
      min_timeout: 90,
      max_timeout: 600,
      retry_attempts: 1,
      thresholds: {
        median_runtime_regression_pct: 45.0,
        p95_runtime_regression_pct: 60.0,
        min_success_rate: 0.8,
        max_elapsed_cv: 0.75,
        quality_score_drop_pct: 20.0,
        quality_score_drop_hard_pct: 55.0,
        high_signal_drop_pct: 25.0,
        total_unique_drop_pct: 30.0
      }
    },
    'fast' => {
      no_cache: false,
      target_tier: 'full',
      default_timeout: 300,
      min_timeout: 90,
      max_timeout: 480,
      retry_attempts: 0,
      thresholds: {
        median_runtime_regression_pct: 65.0,
        p95_runtime_regression_pct: 80.0,
        min_success_rate: 0.6,
        max_elapsed_cv: 1.0,
        quality_score_drop_pct: 25.0,
        quality_score_drop_hard_pct: 60.0,
        high_signal_drop_pct: 30.0,
        total_unique_drop_pct: 35.0
      }
    }
  }.freeze

  DEFAULTS = {
    runs: 1,
    concurrency: 1,
    timeout_s: nil,
    out_dir: File.expand_path('results/bb_live_targets', __dir__),
    nokizaru_bin: File.expand_path('../bin/nokizaru', __dir__),
    skip_existing: false,
    fail_fast: false,
    dry_run: false,
    include_targets: nil,
    strict: nil,
    resource_metrics: true,
    write_baseline: false,
    rolling_window: 0,
    shard_count: 1,
    shard_index: 0,
    target_tier: nil,
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
        '--target',
        target,
        '--full',
        '--export'
      ]
      args << '--no-cache' if no_cache
      args.push(
        '-o',
        'json',
        '--cd',
        out_dir,
        '--of',
        basename,
        '-nb'
      )
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
    puts(
      "[bench] profile=#{@opts[:profile]} tier=#{@opts[:target_tier]} " \
      "shard=#{@opts[:shard_index]}/#{@opts[:shard_count]} queued=#{jobs.length}"
    )

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
      target_tier: opts[:target_tier] || profile_cfg[:target_tier],
      strict: opts[:strict].nil? ? strict_default : opts[:strict],
      thresholds: profile_cfg[:thresholds],
      no_cache: profile_cfg[:no_cache],
      retry_attempts: profile_cfg[:retry_attempts]
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
    tiered = targets_for_tier(@opts[:target_tier])
    configured = @opts[:include_targets]
    targets = if configured.nil? || configured.empty?
                tiered
              else
                selected = tiered.select { |target| configured.include?(self.class.target_key(target)) }
                missing = configured - selected.map { |target| self.class.target_key(target) }
                warn "[bench] warning: unknown targets ignored: #{missing.join(', ')}" unless missing.empty?
                selected
              end

    deduped = dedupe_by_target_key(targets)
    self.class.shard_targets(deduped, @opts[:shard_count], @opts[:shard_index])
  end

  def targets_for_tier(tier_name)
    keys = TARGET_TIERS[tier_name.to_s]
    return TARGETS if keys.nil?

    key_set = keys.each_with_object({}) { |key, out| out[key] = true }
    TARGETS.select { |target| key_set[self.class.target_key(target)] }
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
    command = build_command(job)
    started_at = Time.now.utc
    start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "[bench][w#{worker_id}] run=#{job[:run]} target=#{job[:target]} timeout=#{job[:timeout_s]}s"

    final_status, resources, attempts, exit_code = run_job_attempts(job, command)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic

    puts "[bench][w#{worker_id}] #{job[:basename]} => #{final_status} (#{format('%.2f', elapsed)}s)"

    {
      run: job[:run],
      target: job[:target],
      target_key: job[:target_key],
      basename: job[:basename],
      json_path: job[:json_path],
      log_path: job[:log_path],
      command: command,
      attempts: attempts,
      timeout_s: job[:timeout_s],
      status: final_status,
      timed_out: final_status == 'timeout',
      exit_code: exit_code,
      elapsed_s: elapsed.round(4),
      started_at: started_at.iso8601,
      ended_at: Time.now.utc.iso8601,
      resources: resources
    }
  end

  def run_job_attempts(job, command)
    wrapped_command = command_for_execution(command)
    max_attempts = [@opts[:retry_attempts].to_i + 1, 1].max
    attempts = 0
    logs = []
    final_status = 'failed'
    final_resources = {}
    final_exit_code = nil

    while attempts < max_attempts
      attempts += 1
      cleanup_previous_outputs(job)
      output, status, timed_out, resources = run_command_with_timeout(wrapped_command, job[:timeout_s])
      status_name = classify_status(status, timed_out, job[:json_path])
      logs << "\n[bench-attempt=#{attempts} status=#{status_name}]\n#{output}"

      final_status = status_name
      final_resources = resources
      final_exit_code = status&.exitstatus
      break unless retryable_status?(status_name)
      break if attempts >= max_attempts

      puts "[bench] retrying #{job[:basename]} after #{status_name} (attempt #{attempts + 1}/#{max_attempts})"
    end

    File.write(job[:log_path], logs.join)
    [final_status, final_resources, attempts, final_exit_code]
  end

  def classify_status(status, timed_out, json_path)
    return 'ok' if status&.success? && File.exist?(json_path)

    timed_out ? 'timeout' : 'failed'
  end

  def retryable_status?(status_name)
    %w[timeout failed].include?(status_name)
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
        'target_tier' => @opts[:target_tier],
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
        discovery = successful.filter_map { |row| DiscoveryMetrics.extract(row[:json_path]) }
        discovery_summary = DiscoveryMetrics.aggregate(discovery)

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
        }.merge(discovery_summary)
      end
    end

    def rate(numerator, denominator)
      return 0.0 if denominator.to_i <= 0

      (numerator.to_f / denominator).round(4)
    end
  end

  module DiscoveryMetrics
    module_function

    DEFAULTS = {
      'crawler_total_unique' => 0.0,
      'crawler_high_signal_count' => 0.0,
      'findings_count' => 0.0,
      'subdomain_count' => 0.0,
      'wayback_count' => 0.0,
      'directory_requests' => 0.0,
      'directory_found_count' => 0.0,
      'directory_prioritized_count' => 0.0,
      'directory_prioritized_ratio' => 0.0,
      'directory_low_confidence_ratio' => 0.0,
      'directory_confirmed_ratio' => 0.0,
      'directory_soft_404_reason_ratio' => 0.0,
      'redirect_cluster_dominance_ratio' => 0.0,
      'waf_likelihood_score' => 0.0,
      'sensitive_status_promotion_ratio' => 0.0,
      'sensitive_status_unique_fingerprint_ratio' => 0.0,
      'crawler_blocked' => 0.0,
      'quality_score' => 0.0
    }.freeze

    CRAWLER_BLOCK_STATUS_RE = /HTTP status (403|405|429)\b/

    def extract(path)
      payload = JSON.parse(File.read(path))
      modules = payload.fetch('modules', {})
      crawler_stats = modules.dig('crawler', 'stats') || {}
      subdomains = Array(modules.dig('subdomains', 'subdomains'))
      wayback = Array(modules.dig('wayback', 'urls'))
      dir_metrics = directory_metrics(modules)
      findings = Array(payload['findings'])
      crawler_error = modules.dig('crawler', 'error').to_s

      metrics = {
        'crawler_total_unique' => crawler_stats['total_unique'].to_f,
        'crawler_high_signal_count' => crawler_stats['high_signal_count'].to_f,
        'findings_count' => findings.length.to_f,
        'subdomain_count' => subdomains.length.to_f,
        'wayback_count' => wayback.length.to_f,
        'directory_requests' => dir_metrics['directory_requests'],
        'directory_found_count' => dir_metrics['directory_found_count'],
        'directory_prioritized_count' => dir_metrics['directory_prioritized_count'],
        'directory_prioritized_ratio' => dir_metrics['directory_prioritized_ratio'],
        'directory_low_confidence_ratio' => dir_metrics['directory_low_confidence_ratio'],
        'directory_confirmed_ratio' => dir_metrics['directory_confirmed_ratio'],
        'directory_soft_404_reason_ratio' => dir_metrics['directory_soft_404_reason_ratio'],
        'redirect_cluster_dominance_ratio' => dir_metrics['redirect_cluster_dominance_ratio'],
        'waf_likelihood_score' => dir_metrics['waf_likelihood_score'],
        'sensitive_status_promotion_ratio' => dir_metrics['sensitive_status_promotion_ratio'],
        'sensitive_status_unique_fingerprint_ratio' =>
          dir_metrics['sensitive_status_unique_fingerprint_ratio'],
        'crawler_blocked' => crawler_error.match?(CRAWLER_BLOCK_STATUS_RE) ? 1.0 : 0.0
      }
      metrics['quality_score'] = quality_score(metrics)
      metrics
    rescue StandardError
      nil
    end

    def directory_metrics(modules)
      dir_stats = modules.dig('directory_enum', 'stats') || {}
      dir_reasons = dir_stats['confidence_reasons'].is_a?(Hash) ? dir_stats['confidence_reasons'] : {}
      dir_found = Array(modules.dig('directory_enum', 'found')).length.to_f
      dir_prioritized = Array(modules.dig('directory_enum', 'prioritized_found')).length.to_f
      dir_low = Array(modules.dig('directory_enum', 'low_confidence_found')).length.to_f
      dir_confirmed = Array(modules.dig('directory_enum', 'confirmed_found')).length.to_f
      soft_404_hits = dir_reasons['soft_404_signature_match'].to_f
      sensitive_promotion = dir_stats['waf_sensitive_promotion_count'].to_f

      {
        'directory_requests' => dir_stats['total_requests'].to_f,
        'directory_found_count' => dir_found,
        'directory_prioritized_count' => dir_prioritized,
        'directory_prioritized_ratio' => ratio(dir_prioritized, dir_found),
        'directory_low_confidence_ratio' => ratio(dir_low, dir_found),
        'directory_confirmed_ratio' => ratio(dir_confirmed, dir_found),
        'directory_soft_404_reason_ratio' => ratio(soft_404_hits, dir_found),
        'redirect_cluster_dominance_ratio' => dir_stats['redirect_cluster_dominance_ratio'].to_f,
        'waf_likelihood_score' => dir_stats['waf_likelihood_score'].to_f,
        'sensitive_status_promotion_ratio' => ratio(sensitive_promotion, dir_prioritized),
        'sensitive_status_unique_fingerprint_ratio' =>
          dir_stats['sensitive_status_fingerprint_uniqueness_ratio'].to_f
      }
    end

    def ratio(numerator, denominator)
      return 0.0 unless denominator.to_f.positive?

      numerator.to_f / denominator
    end

    def aggregate(rows)
      return DEFAULTS.dup if rows.empty?

      DEFAULTS.keys.each_with_object({}) do |key, out|
        out[key] = Stats.median(rows.map { |row| row[key].to_f })
      end
    end

    def quality_score(metrics)
      (
        weighted_component(metrics['crawler_high_signal_count'], 0.34) +
        weighted_component(metrics['crawler_total_unique'], 0.23) +
        weighted_component(metrics['directory_prioritized_count'], 0.16) +
        ratio_component(metrics['directory_prioritized_ratio'], 0.08) +
        weighted_component(metrics['findings_count'], 0.10) +
        weighted_component(metrics['subdomain_count'], 0.06) +
        weighted_component(metrics['wayback_count'], 0.02) +
        weighted_component(metrics['directory_requests'], 0.01)
      ).round(4)
    end

    def weighted_component(value, weight)
      Math.log(value.to_f + 1.0) * 100.0 * weight
    end

    def ratio_component(value, weight)
      value.to_f.clamp(0.0, 1.0) * 100.0 * weight
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
      targets.each_with_object({}) do |(target_key, row), snapshot|
        next unless valid_snapshot_row?(row)

        snapshot[target_key] = {
          'elapsed_median_s' => row['elapsed_median_s'].to_f.round(4),
          'elapsed_p95_s' => row['elapsed_p95_s'].to_f.round(4),
          'quality_score' => row['quality_score'].to_f.round(4),
          'crawler_total_unique' => row['crawler_total_unique'].to_f.round(4),
          'crawler_high_signal_count' => row['crawler_high_signal_count'].to_f.round(4),
          'findings_count' => row['findings_count'].to_f.round(4),
          'directory_found_count' => row['directory_found_count'].to_f.round(4),
          'directory_prioritized_count' => row['directory_prioritized_count'].to_f.round(4),
          'directory_prioritized_ratio' => row['directory_prioritized_ratio'].to_f.round(4),
          'directory_low_confidence_ratio' => row['directory_low_confidence_ratio'].to_f.round(4),
          'directory_confirmed_ratio' => row['directory_confirmed_ratio'].to_f.round(4),
          'directory_soft_404_reason_ratio' => row['directory_soft_404_reason_ratio'].to_f.round(4),
          'redirect_cluster_dominance_ratio' => row['redirect_cluster_dominance_ratio'].to_f.round(4),
          'waf_likelihood_score' => row['waf_likelihood_score'].to_f.round(4),
          'sensitive_status_promotion_ratio' => row['sensitive_status_promotion_ratio'].to_f.round(4),
          'sensitive_status_unique_fingerprint_ratio' =>
            row['sensitive_status_unique_fingerprint_ratio'].to_f.round(4),
          'subdomain_count' => row['subdomain_count'].to_f.round(4),
          'wayback_count' => row['wayback_count'].to_f.round(4),
          'crawler_blocked' => row['crawler_blocked'].to_f.round(4)
        }
      end
    end

    def valid_snapshot_row?(row)
      row['success_rate'].to_f.positive? &&
        row['elapsed_median_s'].to_f.positive? &&
        row['elapsed_p95_s'].to_f.positive?
    end

    def write(path, profile, snapshot)
      payload = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      payload[profile] = merged_profile_rows(payload[profile], snapshot)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(payload))
      path
    rescue StandardError
      nil
    end

    def merged_profile_rows(existing, snapshot)
      normalized_existing = existing.is_a?(Hash) ? existing : {}
      normalized_existing.merge(snapshot)
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
      Dir[pattern].last(limit)
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

      rows.transform_values do |values|
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
        'speed_failed_targets' => rows.values.count { |row| row['speed_status'] == 'fail' },
        'quality_failed_targets' => rows.values.count { |row| row['quality_status'] == 'fail' },
        'balanced_score_median' => Stats.median(rows.values.map { |row| row.dig('balance', 'balanced_score').to_f }),
        'exit_code' => exit_code
      }
    end

    def evaluate_target(target_key, metrics, baseline_row, thresholds, strict)
      overall_status = 'pass'
      speed_status = 'pass'
      quality_status = 'pass'
      speed_reasons = []
      quality_reasons = []
      diagnostics = diagnostics_for_target(metrics)

      if metrics['success_rate'].to_f < thresholds[:min_success_rate].to_f
        speed_status = downgrade_status(speed_status, strict)
        overall_status = combine_statuses(overall_status, speed_status)
        speed_reasons << format(
          'success_rate %<actual>.2f below minimum %<minimum>.2f',
          actual: metrics['success_rate'],
          minimum: thresholds[:min_success_rate]
        )
      end

      if metrics['elapsed_cv'].to_f > thresholds[:max_elapsed_cv].to_f
        speed_status = downgrade_status(speed_status, strict)
        overall_status = combine_statuses(overall_status, speed_status)
        speed_reasons << format(
          'elapsed cv %<actual>.2f exceeds %<maximum>.2f',
          actual: metrics['elapsed_cv'],
          maximum: thresholds[:max_elapsed_cv]
        )
      end

      unless baseline_row.is_a?(Hash)
        balance = balance_metrics(metrics, nil)
        combined_reasons = merge_reasons_with_diagnostics(speed_reasons + quality_reasons + ['no baseline available'],
                                                          diagnostics)
        return {
          'target_key' => target_key,
          'status' => (overall_status == 'fail' ? 'fail' : 'warn'),
          'speed_status' => speed_status,
          'quality_status' => quality_status,
          'speed_reasons' => speed_reasons,
          'quality_reasons' => quality_reasons,
          'diagnostics' => diagnostics,
          'reasons' => combined_reasons,
          'baseline' => nil,
          'regression_pct' => regression_hash(0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
          'balance' => balance
        }
      end

      median_delta = regression_pct(metrics['elapsed_median_s'], baseline_row['elapsed_median_s'])
      p95_delta = regression_pct(metrics['elapsed_p95_s'], baseline_row['elapsed_p95_s'])
      quality_score_delta = regression_pct_drop(metrics['quality_score'], baseline_row['quality_score'])
      high_signal_delta = regression_pct_drop(metrics['crawler_high_signal_count'],
                                              baseline_row['crawler_high_signal_count'])
      total_unique_delta = regression_pct_drop(metrics['crawler_total_unique'], baseline_row['crawler_total_unique'])
      findings_delta = regression_pct_drop(metrics['findings_count'], baseline_row['findings_count'])

      if median_delta > thresholds[:median_runtime_regression_pct].to_f
        speed_status = downgrade_status(speed_status, strict)
        overall_status = combine_statuses(overall_status, speed_status)
        speed_reasons << format(
          'median runtime regression %<actual>.2f%% exceeds %<maximum>.2f%%',
          actual: median_delta,
          maximum: thresholds[:median_runtime_regression_pct]
        )
      end

      if p95_delta > thresholds[:p95_runtime_regression_pct].to_f
        speed_status = downgrade_status(speed_status, strict)
        overall_status = combine_statuses(overall_status, speed_status)
        speed_reasons << format(
          'p95 runtime regression %<actual>.2f%% exceeds %<maximum>.2f%%',
          actual: p95_delta,
          maximum: thresholds[:p95_runtime_regression_pct]
        )
      end

      quality_status, overall_status, quality_reasons = apply_quality_checks(
        quality_status,
        overall_status,
        quality_reasons,
        {
          crawler_blocked: metrics['crawler_blocked'].to_f >= 0.5,
          quality_score: quality_score_delta,
          high_signal: high_signal_delta,
          total_unique: total_unique_delta,
          findings: findings_delta
        },
        thresholds,
        strict
      )

      balance = balance_metrics(metrics, baseline_row)

      {
        'target_key' => target_key,
        'status' => overall_status,
        'speed_status' => speed_status,
        'quality_status' => quality_status,
        'speed_reasons' => speed_reasons,
        'quality_reasons' => quality_reasons,
        'diagnostics' => diagnostics,
        'reasons' => merge_reasons_with_diagnostics(speed_reasons + quality_reasons, diagnostics),
        'baseline' => baseline_row,
        'regression_pct' => regression_hash(
          median_delta,
          p95_delta,
          quality_score_delta,
          high_signal_delta,
          total_unique_delta,
          findings_delta
        ),
        'balance' => balance
      }
    end

    def diagnostics_for_target(metrics)
      diagnostics = []
      found = metrics['directory_found_count'].to_f
      prioritized_ratio = metrics['directory_prioritized_ratio'].to_f
      low_ratio = metrics['directory_low_confidence_ratio'].to_f
      soft_404_ratio = metrics['directory_soft_404_reason_ratio'].to_f
      redirect_cluster_ratio = metrics['redirect_cluster_dominance_ratio'].to_f
      waf_likelihood = metrics['waf_likelihood_score'].to_f
      sensitive_promotion_ratio = metrics['sensitive_status_promotion_ratio'].to_f
      sensitive_unique_ratio = metrics['sensitive_status_unique_fingerprint_ratio'].to_f
      crawler_high_signal = metrics['crawler_high_signal_count'].to_f
      wayback_count = metrics['wayback_count'].to_f
      crawler_unique = metrics['crawler_total_unique'].to_f
      prioritized = metrics['directory_prioritized_count'].to_f

      if noisy_directory_saturation?(found, prioritized_ratio)
        diagnostics << 'diag: directory candidates saturated with low prioritization ratio'
      end
      diagnostics << 'diag: directory low-confidence ratio dominates output' if low_confidence_dominates?(found,
                                                                                                          low_ratio)
      diagnostics << 'diag: soft-404 signature dominates directory confidence reasons' if soft_404_ratio >= 0.8
      if redirect_cluster_ratio >= 0.85
        diagnostics << 'diag: redirect cluster dominance suggests canonicalized/WAF-shaped responses'
      end
      if sensitive_status_promotion_overtriggered?(sensitive_promotion_ratio, sensitive_unique_ratio)
        diagnostics << 'diag: sensitive-status promotion likely over-triggered by uniform protection responses'
      end
      diagnostics << 'diag: probable WAF-shaped response landscape' if waf_likelihood >= 0.75
      diagnostics << 'diag: crawler high-signal count reached cap (250)' if crawler_high_signal >= 250.0
      diagnostics << 'diag: wayback-heavy output with weak crawler/dir corroboration' if wayback_corroboration_weak?(
        wayback_count,
        crawler_unique,
        prioritized
      )

      diagnostics
    end

    def noisy_directory_saturation?(found, prioritized_ratio)
      found >= 1000.0 && prioritized_ratio < 0.01
    end

    def low_confidence_dominates?(found, low_ratio)
      found >= 200.0 && low_ratio >= 0.95
    end

    def sensitive_status_promotion_overtriggered?(sensitive_promotion_ratio, sensitive_unique_ratio)
      sensitive_promotion_ratio >= 0.7 && sensitive_unique_ratio <= 0.2
    end

    def wayback_corroboration_weak?(wayback_count, crawler_unique, prioritized)
      wayback_count >= 500.0 && crawler_unique < 50.0 && prioritized < 10.0
    end

    def merge_reasons_with_diagnostics(reasons, diagnostics)
      base = Array(reasons)
      return base if diagnostics.empty?

      base + diagnostics.first(2)
    end

    def regression_hash(median_delta, p95_delta, quality_score_delta, high_signal_delta, total_unique_delta,
                        findings_delta)
      {
        'elapsed_median_s' => median_delta.round(4),
        'elapsed_p95_s' => p95_delta.round(4),
        'quality_score' => quality_score_delta.round(4),
        'crawler_high_signal_count' => high_signal_delta.round(4),
        'crawler_total_unique' => total_unique_delta.round(4),
        'findings_count' => findings_delta.round(4)
      }
    end

    def quality_drop_actionable?(deltas, thresholds)
      quality_score_delta = deltas[:quality_score]
      high_signal_delta = deltas[:high_signal]
      total_unique_delta = deltas[:total_unique]
      findings_delta = deltas[:findings]
      return false unless quality_score_delta > thresholds[:quality_score_drop_pct].to_f
      return quality_score_delta > thresholds[:quality_score_drop_hard_pct].to_f if deltas[:crawler_blocked]

      high_signal_delta > thresholds[:high_signal_drop_pct].to_f ||
        total_unique_delta > thresholds[:total_unique_drop_pct].to_f ||
        findings_delta > thresholds[:total_unique_drop_pct].to_f ||
        quality_score_delta > thresholds[:quality_score_drop_hard_pct].to_f
    end

    def apply_quality_checks(quality_status, overall_status, quality_reasons, deltas, thresholds, strict)
      checks = []
      if quality_drop_actionable?(deltas, thresholds)
        checks << ['quality score drop %<actual>.2f%% exceeds %<maximum>.2f%%', deltas[:quality_score],
                   thresholds[:quality_score_drop_pct]]
      end
      if !deltas[:crawler_blocked] && deltas[:high_signal] > thresholds[:high_signal_drop_pct].to_f
        checks << ['high-signal drop %<actual>.2f%% exceeds %<maximum>.2f%%', deltas[:high_signal],
                   thresholds[:high_signal_drop_pct]]
      end
      if !deltas[:crawler_blocked] && deltas[:total_unique] > thresholds[:total_unique_drop_pct].to_f
        checks << ['unique-url drop %<actual>.2f%% exceeds %<maximum>.2f%%', deltas[:total_unique],
                   thresholds[:total_unique_drop_pct]]
      end
      if !deltas[:crawler_blocked] && deltas[:findings] > thresholds[:total_unique_drop_pct].to_f
        checks << ['findings drop %<actual>.2f%% exceeds %<maximum>.2f%%', deltas[:findings],
                   thresholds[:total_unique_drop_pct]]
      end

      checks.each do |template, actual, maximum|
        quality_status = downgrade_status(quality_status, strict)
        overall_status = combine_statuses(overall_status, quality_status)
        quality_reasons << format(template, actual: actual, maximum: maximum)
      end

      [quality_status, overall_status, quality_reasons]
    end

    def regression_pct(current, baseline)
      base = baseline.to_f
      return 0.0 if base <= 0.0

      ((current.to_f - base) / base) * 100.0
    end

    def regression_pct_drop(current, baseline)
      base = baseline.to_f
      return 0.0 if base <= 0.0

      [((base - current.to_f) / base) * 100.0, 0.0].max
    end

    def balance_metrics(metrics, baseline_row)
      speed_retention = retention_pct(baseline_row&.[]('elapsed_median_s'), metrics['elapsed_median_s'], inverse: true)
      quality_retention = retention_pct(baseline_row&.[]('quality_score'), metrics['quality_score'])
      {
        'speed_retention_pct' => speed_retention.round(4),
        'quality_retention_pct' => quality_retention.round(4),
        'balanced_score' => Math.sqrt(speed_retention * quality_retention).round(4)
      }
    end

    def retention_pct(baseline, current, inverse: false)
      base = baseline.to_f
      return 100.0 if base <= 0.0

      current_value = current.to_f
      return 0.0 if inverse && current_value <= 0.0

      ratio = inverse ? (base / current_value) : (current_value / base)
      (ratio * 100.0).clamp(0.0, 200.0)
    end

    def downgrade_status(current_status, strict)
      return 'fail' if current_status == 'fail'

      strict ? 'fail' : 'warn'
    end

    def combine_statuses(current_status, new_status)
      return 'fail' if [current_status, new_status].include?('fail')
      return 'warn' if [current_status, new_status].include?('warn')

      'pass'
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
      lines << '| Target | Success Rate | Median (s) | Quality | Balance | Speed | Quality | Verdict | Notes |'
      lines << '| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |'

      rows.keys.sort.each do |target_key|
        row = rows.fetch(target_key)
        verdict = verdicts.fetch(target_key, {})
        notes = Array(verdict['reasons']).join('; ')
        lines << [
          target_key,
          format('%.2f', row['success_rate'].to_f),
          format('%.2f', row['elapsed_median_s'].to_f),
          format('%.2f', row['quality_score'].to_f),
          format('%.2f', verdict.dig('balance', 'balanced_score').to_f),
          verdict.fetch('speed_status', 'n/a'),
          verdict.fetch('quality_status', 'n/a'),
          verdict.fetch('status', 'n/a'),
          notes.empty? ? '-' : notes
        ].join(' | ').prepend('| ').concat(' |')
      end

      lines << ''
      passed = manifest.dig('verdict', 'passed_targets')
      warned = manifest.dig('verdict', 'warning_targets')
      failed = manifest.dig('verdict', 'failed_targets')
      speed_failed = manifest.dig('verdict', 'speed_failed_targets')
      quality_failed = manifest.dig('verdict', 'quality_failed_targets')
      balance_median = manifest.dig('verdict', 'balanced_score_median')
      verdict_line = [
        'Verdict: pass=%<passed>d warn=%<warned>d fail=%<failed>d',
        'speed_fail=%<speed>d quality_fail=%<quality>d',
        'balance_median=%<balance>.2f'
      ].join(' ')
      lines << format(
        verdict_line,
        passed: passed,
        warned: warned,
        failed: failed,
        speed: speed_failed,
        quality: quality_failed,
        balance: balance_median.to_f
      )
      lines.join("\n")
    end
  end
end

def configure_live_suite_option_parser(parser, opts)
  parser.banner = 'Usage: ruby bench/bb_live_target_suite.rb [options]'
  parser.on('--profile NAME', %w[canonical fast], 'Execution profile (canonical or fast)') do |value|
    opts[:profile] = value
  end
  parser.on('--tier NAME', %w[stable full], 'Target tier filter (stable or full)') do |value|
    opts[:target_tier] = value
  end
  parser.on('--runs N', Integer, 'How many repetitions to run') { |value| opts[:runs] = [value.to_i, 1].max }
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
  parser.on('--baseline PATH', String, 'Baseline file path') { |value| opts[:baseline_path] = File.expand_path(value) }
  parser.on('--rolling-window N', Integer, 'Use last N manifests as rolling baseline') do |value|
    opts[:rolling_window] = [value.to_i, 0].max
  end
  parser.on('--write-baseline', 'Write medians/p95 from current run to baseline file') { opts[:write_baseline] = true }
  parser.on('--strict', 'Force strict pass/fail behavior') { opts[:strict] = true }
  parser.on('--no-strict', 'Force warning behavior for regressions') { opts[:strict] = false }
  parser.on('--resource-metrics', 'Capture cpu/rss with /usr/bin/time') { opts[:resource_metrics] = true }
  parser.on('--no-resource-metrics', 'Disable cpu/rss collection') { opts[:resource_metrics] = false }
  parser.on('--skip-existing', 'Skip runs when output JSON exists') { opts[:skip_existing] = true }
  parser.on('--no-skip-existing', 'Always rerun even if output JSON exists (default)') { opts[:skip_existing] = false }
  parser.on('--fail-fast', 'Stop remaining queue after first non-ok result') { opts[:fail_fast] = true }
  parser.on('--dry-run', 'Print generated commands and exit') { opts[:dry_run] = true }
end

def parse_options(argv)
  opts = BBLiveTargetSuite::DEFAULTS.dup

  OptionParser.new do |parser|
    configure_live_suite_option_parser(parser, opts)
  end.parse!(argv)

  opts
end

if $PROGRAM_NAME == __FILE__
  options = parse_options(ARGV)
  runner = BBLiveTargetSuite.new(options)
  exit(runner.run)
end
