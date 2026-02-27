#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'timeout'
require 'uri'

class LiveSuiteFullBenchmark
  DEFAULT_TARGETS = [
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

  DEFAULTS = {
    runs: 1,
    concurrency: 1,
    timeout_s: 420,
    out_dir: File.expand_path('results/live_suite', __dir__),
    nokizaru_bin: File.expand_path('../bin/nokizaru', __dir__),
    skip_existing: true,
    fail_fast: false,
    dry_run: false,
    include_targets: nil
  }.freeze

  def self.target_key(url)
    uri = URI.parse(url)
    host = uri.host.to_s.downcase
    host.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  rescue URI::InvalidURIError
    url.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  def self.build_command(nokizaru_bin:, target:, out_dir:, basename:)
    [
      RbConfig.ruby,
      nokizaru_bin,
      '--url',
      target,
      '--full',
      '--export',
      '--no-cache',
      '-o',
      'json',
      '--cd',
      out_dir,
      '--of',
      basename,
      '-nb'
    ]
  end

  def initialize(opts)
    @opts = opts
    @results = []
    @result_mutex = Mutex.new
  end

  def run
    ensure_paths!
    jobs = build_jobs
    puts "[bench] queued #{jobs.length} full scans"

    return print_planned_jobs(jobs) if @opts[:dry_run]

    execute_jobs(jobs)
    manifest_path = write_manifest
    print_summary(manifest_path)
  end

  private

  def ensure_paths!
    FileUtils.mkdir_p(@opts[:out_dir])
    FileUtils.mkdir_p(log_dir)
    return if File.exist?(@opts[:nokizaru_bin])

    raise "nokizaru executable not found: #{@opts[:nokizaru_bin]}"
  end

  def build_jobs
    targets = selected_targets
    jobs = []

    (1..@opts[:runs]).each do |run_index|
      targets.each do |target|
        key = self.class.target_key(target)
        basename = "full_r#{run_index}_#{key}"
        json_path = File.join(@opts[:out_dir], "#{basename}.json")
        next if @opts[:skip_existing] && File.exist?(json_path)

        jobs << {
          run: run_index,
          target: target,
          target_key: key,
          basename: basename,
          json_path: json_path,
          log_path: File.join(log_dir, "#{basename}.log")
        }
      end
    end

    jobs
  end

  def selected_targets
    configured = @opts[:include_targets]
    targets = if configured.nil? || configured.empty?
                DEFAULT_TARGETS
              else
                selected = DEFAULT_TARGETS.select { |target| configured.include?(self.class.target_key(target)) }
                missing = configured - selected.map { |target| self.class.target_key(target) }
                warn "[bench] warning: unknown targets ignored: #{missing.join(', ')}" unless missing.empty?
                selected
              end

    dedupe_by_target_key(targets)
  end

  def dedupe_by_target_key(targets)
    seen = {}
    Array(targets).each_with_object([]) do |target, list|
      key = self.class.target_key(target)
      next if seen[key]

      seen[key] = true
      list << target
    end
  end

  def print_planned_jobs(jobs)
    jobs.each do |job|
      command = self.class.build_command(
        nokizaru_bin: @opts[:nokizaru_bin],
        target: job[:target],
        out_dir: @opts[:out_dir],
        basename: job[:basename]
      )
      puts "[dry-run] #{command.join(' ')}"
    end
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
    command = self.class.build_command(
      nokizaru_bin: @opts[:nokizaru_bin],
      target: job[:target],
      out_dir: @opts[:out_dir],
      basename: job[:basename]
    )
    started_at = Time.now.utc
    start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "[bench][w#{worker_id}] run=#{job[:run]} target=#{job[:target]}"

    output, status, timed_out = run_command_with_timeout(command, @opts[:timeout_s])
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
      status: final_status,
      timed_out: timed_out,
      exit_code: status&.exitstatus,
      elapsed_s: elapsed.round(4),
      started_at: started_at.iso8601,
      ended_at: Time.now.utc.iso8601
    }
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

    [output, status, timed_out]
  rescue StandardError => e
    ["runner exception: #{e.class} #{e.message}\n", nil, false]
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

  def write_manifest
    path = File.join(@opts[:out_dir], "full_suite_manifest_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
    payload = {
      generated_at: Time.now.utc.iso8601,
      version: 1,
      config: {
        runs: @opts[:runs],
        concurrency: @opts[:concurrency],
        timeout_s: @opts[:timeout_s],
        out_dir: @opts[:out_dir],
        nokizaru_bin: @opts[:nokizaru_bin],
        skip_existing: @opts[:skip_existing],
        fail_fast: @opts[:fail_fast]
      },
      results: @results.sort_by { |row| [row[:run], row[:target_key]] }
    }
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  def print_summary(manifest_path)
    total = @results.length
    ok = @results.count { |row| row[:status] == 'ok' }
    failed = @results.count { |row| row[:status] == 'failed' }
    timed_out = @results.count { |row| row[:status] == 'timeout' }
    puts "[bench] done total=#{total} ok=#{ok} failed=#{failed} timeout=#{timed_out}"
    puts "[bench] manifest=#{manifest_path}"
  end

  def log_dir
    File.join(@opts[:out_dir], 'logs')
  end
end

def parse_options(argv)
  opts = LiveSuiteFullBenchmark::DEFAULTS.dup

  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby bench/live_suite_full_benchmark.rb [options]'

    parser.on('--runs N', Integer, 'How many full-suite repetitions to run (default: 1)') do |value|
      opts[:runs] = [value.to_i, 1].max
    end

    parser.on('--concurrency N', Integer, 'Concurrent targets to run at once (default: 1)') do |value|
      opts[:concurrency] = value.to_i.clamp(1, 10)
    end

    parser.on('--timeout S', Integer, 'Per-target timeout in seconds (default: 420)') do |value|
      opts[:timeout_s] = [value.to_i, 30].max
    end

    parser.on('--out DIR', String, 'Output directory for JSON and logs') do |value|
      opts[:out_dir] = File.expand_path(value)
    end

    parser.on('--nokizaru PATH', String, 'Path to nokizaru executable (default: ./bin/nokizaru)') do |value|
      opts[:nokizaru_bin] = File.expand_path(value)
    end

    parser.on('--targets x,y,z', Array, 'Target keys subset (example: httpbin_org,github_com)') do |value|
      opts[:include_targets] = Array(value).map { |item| item.to_s.strip.downcase }.reject(&:empty?)
    end

    parser.on('--skip-existing', 'Skip runs when output JSON already exists (default)') do
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
  runner = LiveSuiteFullBenchmark.new(options)
  runner.run
end
