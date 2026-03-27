# frozen_string_literal: true

require 'set'
require 'securerandom'
require 'timeout'
require 'zlib'
require 'uri'

require_relative '../http_client'
require_relative '../http_result'
require_relative '../log'
require_relative '../target_intel'
require_relative '../interrupt_state'

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0'
      DEFAULT_EFFECTIVE_TIMEOUT_S = 8.0
      MAX_EFFECTIVE_TIMEOUT_S = 12.0
      SOFT_404_PROBES = 3
      SOFT_404_MIN_PROBES = 2
      SOFT_404_MIN_TOLERANCE = 128
      SOFT_404_MAX_TOLERANCE = 4096
      SOFT_404_MIN_LEARNING_SAMPLES = 24
      SOFT_404_MAX_LEARNING_SAMPLES = 96
      SOFT_404_MIN_DOMINANCE_RATIO = 0.6
      PROGRESS_EVERY = 1
      PROGRESS_RENDER_INTERVAL_S = 0.08
      PROGRESS_PLAIN_EVERY = 50
      PROTECTED_TIMEOUT_S = 2.5
      MIN_ADAPTIVE_TIMEOUT_S = 1.5
      TIMEOUT_ADAPT_SAMPLE_SIZE = 240
      TIMEOUT_ADAPT_ERROR_RATIO = 0.2
      PREFLIGHT_RANDOM_PROBES = 6
      PREFLIGHT_TOTAL_PROBES = 12
      PREFLIGHT_TIMEOUT_S = 1.5
      PREFLIGHT_HOSTILE_MIN_SUCCESS_RATIO = 0.35
      PREFLIGHT_HOSTILE_TIMEOUT_RATIO = 0.25
      PREFLIGHT_HOSTILE_ERROR_RATIO = 0.75
      PREFLIGHT_SEEDED_ERROR_RATIO = 0.2
      PREFLIGHT_SEEDED_TIMEOUT_RATIO = 0.1
      REQUEST_HARD_TIMEOUT_PADDING_S = 0.75
      REQUEST_HARD_TIMEOUT_MIN_S = 1.0
      REQUEST_HARD_TIMEOUT_MAX_S = 6.0
      LOW_INFORMATION_BODY_BYTES = 24
      TEXTUAL_CONTENT_TYPES = %w[text/html text/plain application/json application/xml].freeze
      WAF_LIKELIHOOD_HIGH = 0.75
      WAF_REDIRECT_CLUSTER_DOMINANCE = 0.85
      WAF_SENSITIVE_HOMOGENEITY = 0.8
      WAF_SENSITIVE_UNIQUENESS_LOW = 0.2

      MODE_FULL = 'full'
      MODE_SEEDED = 'seeded'
      MODE_HOSTILE = 'hostile'

      MODE_BUDGETS = {
        MODE_FULL => { budget_s: 0.0, max_requests: 0 },
        MODE_SEEDED => { budget_s: 0.0, max_requests: 0 },
        MODE_HOSTILE => { budget_s: 0.0, max_requests: 0 }
      }.freeze
      HIGH_SIGNAL_PATHS = %w[
        /robots.txt
        /sitemap.xml
        /.git/HEAD
        /.env
        /admin
        /login
        /signin
        /auth
        /account
        /dashboard
        /api
        /graphql
        /wp-admin
        /wp-login.php
        /xmlrpc.php
        /wp-json
        /server-status
        /server-info
      ].freeze
      REDIRECT_STATUSES = Set[301, 302, 303, 307, 308].freeze
      SOFT_404_SAMPLE_STATUSES = Set[200, 204, 301, 302, 303, 307, 308, 401, 403, 405, 500].freeze

      INTERESTING_STATUSES = Set[200, 204, 401, 403, 405, 500].freeze
      FINDING_CANDIDATE_STATUSES = (INTERESTING_STATUSES + REDIRECT_STATUSES).freeze

      # Run this module and store normalized results in the run context
      def call(target, threads, timeout_s, wdlist, *args)
        options = build_call_options(target, threads, timeout_s, wdlist, *args)
        scan = prepare_scan(options)
        print_banner(scan)

        runtime = init_runtime(scan)
        run_workers(scan, runtime)
        finalize_scan(scan, runtime)
      end

      def build_call_options(target, threads, timeout_s, wdlist, *args)
        allow_redirects, verify_ssl, filext, ctx, request_headers = args
        {
          target: target,
          threads: threads,
          timeout_s: timeout_s,
          wdlist: wdlist,
          allow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          filext: filext,
          ctx: ctx,
          request_headers: request_headers || {}
        }
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def prepare_scan(options)
        anchor = resolve_anchor(options[:target], options[:ctx], options[:verify_ssl], options[:timeout_s])
        scan_target = anchor[:effective_target]
        normalized_target = normalize_target_base(scan_target)
        preflight = preflight_probe(
          normalized_target,
          verify_ssl: options[:verify_ssl],
          allow_redirects: options[:allow_redirects],
          request_headers: options[:request_headers]
        )
        word_data = load_words(options[:wdlist])
        scan_mode = mode_data(preflight, options, anchor)
        urls = build_scan_urls(
          {
            target: normalized_target,
            words: word_data[:words],
            filext: options[:filext],
            ctx: options[:ctx]
          }
        )
        soft_404_baseline = build_initial_soft_404_baseline(normalized_target, scan_mode[:timeout], options)

        {
          options: options,
          anchor: anchor,
          scan_target: scan_target,
          normalized_target: normalized_target,
          preflight: preflight,
          word_data: word_data,
          mode: scan_mode[:mode],
          budgets: scan_mode[:budgets],
          timeout: scan_mode[:timeout],
          soft_404_baseline: soft_404_baseline,
          urls: urls,
          total_urls: urls.length,
          reanchor_display: "#{scan_target} (#{anchor[:reason_code]})"
        }
      end

      def mode_data(preflight, options, anchor)
        mode = choose_mode(preflight)
        {
          mode: mode,
          budgets: MODE_BUDGETS.fetch(mode),
          timeout: timeout_for_mode(mode, base_timeout(options, anchor))
        }
      end

      def base_timeout(options, anchor)
        effective_timeout_s(
          options[:timeout_s],
          target_profile: anchor[:profile],
          header_map: options[:ctx].run.dig('modules', 'headers', 'headers'),
          allow_redirects: options[:allow_redirects]
        )
      end

      def build_initial_soft_404_baseline(target, timeout, options)
        client = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: follow_redirects_for_client(options[:allow_redirects], options[:request_headers]),
          verify_ssl: options[:verify_ssl],
          max_concurrent: 1,
          retries: 0
        )
        build_soft_404_baseline(
          client,
          target,
          request_headers: options[:request_headers],
          allow_redirects: options[:allow_redirects],
          request_timeout: timeout
        )
      rescue StandardError
        nil
      ensure
        client.close if client.respond_to?(:close)
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def init_runtime(scan)
        {
          mutex: Mutex.new,
          responses: [],
          signal_responses: [],
          found: [],
          stdout_found: [],
          confirmed_found: [],
          low_confidence_found: [],
          all_found: [],
          redirect_signals: init_redirect_signals,
          soft_404_baseline: scan[:soft_404_baseline],
          soft_404_learning: init_soft_404_learning,
          soft_404_state: init_soft_404_state,
          confidence_context: init_confidence_context(scan),
          stats: init_stats,
          issued: 0,
          count: 0,
          start_time: Time.now,
          queue: build_work_queue(scan[:urls]),
          timeout_state: { current: scan[:timeout], min: MIN_ADAPTIVE_TIMEOUT_S },
          stop_state: init_stop_state(scan),
          progress_ui: init_progress_ui
        }
      end

      def init_progress_ui
        {
          started_at_mono: nil,
          last_render_at: nil,
          last_plain_count: 0,
          ticker_active: false,
          ticker_stop: false,
          ticker_thread: nil
        }
      end

      def init_stats
        {
          success: 0,
          errors: 0,
          timeout_downshifts: 0,
          positive_statuses: Hash.new(0),
          confidence_levels: Hash.new(0),
          confidence_reasons: Hash.new(0),
          waf_sensitive_promotion_count: 0,
          error_kinds: Hash.new(0)
        }
      end

      def init_redirect_signals
        {
          counts: {
            cross_scope: 0,
            callback_like: 0,
            auth_flow: 0
          },
          examples: []
        }
      end

      def init_stop_state(scan)
        {
          stop: false,
          reason: nil,
          mode: scan[:mode],
          budgets: scan[:budgets],
          preflight: scan[:preflight],
          request_method: request_method_for_mode(scan[:mode]),
          request_timeout: scan[:timeout],
          request_headers: scan[:options][:request_headers],
          allow_redirects: scan[:options][:allow_redirects],
          client_closed: false
        }
      end

      def build_work_queue(urls)
        queue = Queue.new
        urls.each { |url| queue << url }
        queue
      end

      def run_workers(scan, runtime)
        num_workers = [thread_cap_for_mode(scan[:mode], scan[:options][:threads].to_i), 1].max
        prepare_runtime_client!(scan, runtime, num_workers)
        start_progress_ticker!(runtime, scan)
        workers = Array.new(num_workers) { Thread.new { run_worker_loop(scan, runtime) } }
        workers.each(&:join)
      ensure
        stop_progress_ticker!(runtime) if runtime
        close_client!(runtime[:stop_state], runtime[:client]) if runtime
      end

      def start_progress_ticker!(runtime, scan)
        return unless progress_output_tty?

        ui = runtime[:progress_ui]
        ui[:ticker_active] = true
        ui[:ticker_stop] = false
        ui[:started_at_mono] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ui[:ticker_thread] = Thread.new do
          loop do
            break if ui[:ticker_stop]

            runtime[:mutex].synchronize do
              print_progress(runtime, scan, force: true)
            end
            sleep(PROGRESS_RENDER_INTERVAL_S)
          end
        end
      end

      def stop_progress_ticker!(runtime)
        ui = runtime[:progress_ui]
        return unless ui[:ticker_active]

        ui[:ticker_stop] = true
        thread = ui[:ticker_thread]
        thread&.join(0.2)
        ui[:ticker_active] = false
        ui[:ticker_thread] = nil
      end

      def prepare_runtime_client!(scan, runtime, num_workers)
        runtime[:client] = build_bulk_client(scan, num_workers)
      end

      def build_bulk_client(scan, num_workers)
        Nokizaru::HTTPClient.for_bulk_requests(
          scan[:scan_target],
          timeout_s: scan[:timeout],
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: follow_redirects_for_client(scan[:options][:allow_redirects],
                                                        scan[:options][:request_headers]),
          verify_ssl: scan[:options][:verify_ssl],
          max_concurrent: num_workers,
          retries: 0
        )
      end

      def follow_redirects_for_client(allow_redirects, request_headers)
        allow_redirects && Nokizaru::RequestHeaders.none?(request_headers)
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def run_worker_loop(scan, runtime)
        error_streak = 0
        loop do
          url = pop_queue_url(runtime[:queue])
          break unless worker_active?(url, runtime[:stop_state])
          break unless reserve_request_slot!(runtime)

          error_streak = process_worker_url(scan, runtime, url, error_streak)
        end
      end

      def pop_queue_url(queue)
        queue.pop(true)
      rescue ThreadError
        nil
      end

      def worker_active?(url, stop_state)
        url && !stop_state[:stop] && !Nokizaru::InterruptState.interrupted?
      end

      # Reserve one request slot before dispatch so request budgets remain strict under concurrency
      def reserve_request_slot!(runtime)
        runtime[:mutex].synchronize do
          return false if should_stop_now?(runtime[:issued], runtime[:start_time], runtime[:stop_state])

          runtime[:issued] += 1
          true
        end
      end

      def process_worker_url(scan, runtime, url, error_streak)
        http_result = worker_http_result(runtime, url)
        return process_worker_error(scan, runtime, url, http_result, error_streak + 1) unless http_result.success?

        process_worker_success(scan, runtime, url, http_result)
        0
      rescue StandardError => e
        handle_worker_exception(runtime, url, e, error_streak)
      end

      def worker_http_result(runtime, url)
        raw_resp = request_url(runtime[:client], url, runtime[:stop_state])
        HttpResult.new(raw_resp)
      end

      def handle_worker_exception(runtime, url, error, error_streak)
        process_worker_exception(runtime, url, error)
        next_streak = error_streak + 1
        sleep(error_backoff_s(next_streak, runtime[:stop_state][:mode]))
        next_streak
      end

      def process_worker_success(scan, runtime, url, http_result)
        runtime[:mutex].synchronize do
          process_synchronized_success(scan, runtime, url, http_result)
        end
      end

      def process_synchronized_success(scan, runtime, url, http_result)
        increment_count!(runtime[:stats], runtime)
        handle_runtime_adaptation!(scan, runtime)
        handle_success_status(scan, runtime, url, http_result)
        print_progress(runtime, scan) if (runtime[:count] % PROGRESS_EVERY).zero?
      end

      def increment_count!(stats, runtime)
        stats[:success] += 1
        runtime[:count] += 1
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def handle_runtime_adaptation!(scan, runtime)
        maybe_stop!(runtime)
        return unless apply_mode_downgrade!(runtime[:count], runtime[:stats], runtime[:stop_state],
                                            runtime[:timeout_state])

        rebuild = rebuild_client(client_config(scan, runtime))
        runtime[:client], runtime[:timeout_state] = rebuild
        runtime[:stop_state][:request_timeout] = runtime[:timeout_state][:current]
      end

      def handle_success_status(scan, runtime, url, http_result)
        status = http_result.status.to_i
        runtime[:responses] << [url, status]
        track_raw_finding(runtime[:all_found], scan[:scan_target], url, status)
        runtime[:signal_responses] << [url, status] if SOFT_404_SAMPLE_STATUSES.include?(status)
        track_redirect_signal(runtime[:redirect_signals], url, http_result, status)
        return unless FINDING_CANDIDATE_STATUSES.include?(status)

        sample = response_sample(http_result, request_url: url)
        baseline = update_soft_404_runtime_baseline!(runtime, sample)
        decision = finding_confidence(url, status, sample, baseline, scan[:normalized_target])
        update_confidence_context!(runtime, status, sample, baseline, decision)
        decision = apply_waf_confidence_adjustment(
          decision,
          status,
          sample,
          url,
          scan[:normalized_target],
          confidence_context_snapshot(runtime)
        )
        track_confidence_finding(scan, runtime, url, status, decision)
      end

      def track_raw_finding(all_found, target, url, status)
        return if url == "#{target}/"
        return unless FINDING_CANDIDATE_STATUSES.include?(status)

        all_found << url
      end

      def update_soft_404_runtime_baseline!(runtime, sample)
        state = runtime[:soft_404_state]
        baseline = runtime[:soft_404_baseline]
        learning = runtime[:soft_404_learning]
        return baseline if sample.nil?
        return baseline unless soft_404_active?(state, baseline)

        record_soft_404_sample!(state)
        runtime[:soft_404_baseline] = learn_soft_404_baseline(sample, baseline, learning)
        disable_soft_404_if_unstable!(state, runtime[:soft_404_baseline], learning)
        runtime[:soft_404_baseline]
      end

      def track_confidence_finding(scan, runtime, url, status, decision)
        confidence = decision[:level].to_sym
        reason = decision[:reason].to_s
        update_confidence_stats!(runtime[:stats], confidence, reason, status)
        print_finding(scan, runtime, url, status)
        assign_confidence_bucket(runtime, url, confidence)
      end

      def update_confidence_stats!(stats, confidence, reason, status)
        stats[:confidence_levels][confidence.to_s] += 1
        stats[:confidence_reasons][reason] += 1 unless reason.empty?
        stats[:waf_sensitive_promotion_count] += 1 if confidence != :low && sensitive_status_reason?(reason)
        stats[:positive_statuses][status] += 1
      end

      def assign_confidence_bucket(runtime, url, confidence)
        if confidence == :confirmed
          runtime[:confirmed_found] << url
          runtime[:found] << url
        elsif confidence == :likely
          runtime[:found] << url
        else
          runtime[:low_confidence_found] << url
        end
      end

      def track_redirect_signal(redirect_signals, request_url, http_result, status)
        return unless redirect_status?(status)

        signal_type = redirect_signal_type(request_url, http_result)
        return unless signal_type

        redirect_signals[:counts][signal_type] += 1
        push_redirect_example(redirect_signals[:examples], signal_type, status, request_url, http_result)
      end

      def process_worker_error(scan, runtime, url, http_result, error_streak)
        error_kind = classify_error(http_result)
        runtime[:mutex].synchronize do
          record_worker_error!(runtime, url, http_result, error_kind)
          maybe_stop!(runtime)
          adapt_timeout_if_needed!(scan, runtime)
          print_progress(runtime, scan) if (runtime[:count] % PROGRESS_EVERY).zero?
        end

        sleep(error_backoff_s(error_streak, runtime[:stop_state][:mode]))
        error_streak
      end

      def record_worker_error!(runtime, url, http_result, error_kind)
        runtime[:stats][:errors] += 1
        runtime[:stats][:error_kinds][error_kind] += 1
        runtime[:count] += 1
        log_error(url, http_result, runtime[:stats][:errors])
      end

      def process_worker_exception(runtime, url, error)
        runtime[:mutex].synchronize do
          runtime[:stats][:errors] += 1
          runtime[:count] += 1
          Log.write("[dirrec] Exception for #{url}: #{error.class}") if runtime[:stats][:errors] <= 5
        end
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def maybe_stop!(runtime)
        return unless should_stop_now?(runtime[:count], runtime[:start_time], runtime[:stop_state])

        stop!(runtime[:stop_state], runtime[:count], runtime[:start_time], runtime[:client])
      end

      def adapt_timeout_if_needed!(scan, runtime)
        return unless should_adapt_timeout?(runtime[:count], runtime[:stats], runtime[:timeout_state])

        rebuild = rebuild_client_with_lower_timeout(client_config(scan, runtime))
        runtime[:client], runtime[:timeout_state] = rebuild
        runtime[:stop_state][:request_timeout] = runtime[:timeout_state][:current]
        runtime[:stats][:timeout_downshifts] += 1
        clear_progress_line
        UI.row(:plus, 'Adaptive Timeout', "reduced to #{runtime[:timeout_state][:current]}s (timeout-heavy target)")
        print_progress(runtime, scan, force: true) if progress_output_tty?
      end

      def client_config(scan, runtime)
        {
          client: runtime[:client],
          timeout_state: runtime[:timeout_state],
          target: scan[:scan_target],
          allow_redirects: scan[:options][:allow_redirects],
          request_headers: scan[:options][:request_headers],
          verify_ssl: scan[:options][:verify_ssl],
          threads: thread_cap_for_mode(runtime[:stop_state][:mode], scan[:options][:threads].to_i)
        }
      end

      def finalize_scan(scan, runtime)
        runtime[:stats][:elapsed] = Time.now - runtime[:start_time]
        print_progress(runtime, scan, force: true)
        clear_progress_line
        dir_output(runtime: runtime, scan: scan)
        Log.write('[dirrec] Completed')
      end

      # Resolve directory enum anchor target from shared headers profile or local profile fetch
      def resolve_anchor(target, ctx, verify_ssl, timeout_s)
        profile = ctx.run.dig('modules', 'headers', 'target_profile')
        unless profile.is_a?(Hash)
          profile = Nokizaru::TargetIntel.profile(
            target,
            verify_ssl: verify_ssl,
            timeout_s: [timeout_s.to_f, 10.0].min,
            request_headers: ctx.options[:request_headers] || {}
          )
        end

        decision = Nokizaru::TargetIntel.reanchor_decision(target, profile)
        decision[:profile] = profile
        decision[:reason] = profile['reason'].to_s
        decision[:reason_code] ||= Nokizaru::TargetIntel.reason_code_for(profile)
        decision
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Print a discovered directory finding with status and context
      def print_finding(scan, runtime, url, status)
        target = scan[:scan_target]
        return if url == "#{target}/"

        runtime[:stdout_found] << url
        clear_progress_line
        UI.line(:info, "#{colorize_status(status)} | #{url}")
        print_progress(runtime, scan, force: true) if progress_output_tty?
      end

      # Colorize status code so findings are easy to scan at a glance
      def colorize_status(status)
        code = status.to_i
        color = if [200, 401, 403, 500].include?(code)
                  UI::G
                elsif [204, 301, 302, 303, 307, 308, 405].include?(code)
                  UI::Y
                else
                  UI::R
                end
        "#{color}#{code}#{UI::W}"
      end

      # Log directory scan errors without interrupting worker progress
      def log_error(_url, http_result, error_count)
        return if error_count > 5

        if error_count == 5
          Log.write('[dirrec] Suppressing further error logs')
        else
          Log.write("[dirrec] Error: #{http_result.error_message}")
        end
      end

      # Print directory scan banner and run configuration details
      def print_banner(scan)
        UI.module_header('Starting Directory Enum...')
        rows = banner_rows(scan)
        rows.insert(3, ['Effective Timeout', scan[:timeout]]) if effective_timeout_changed?(scan)
        UI.rows(:plus, rows)
        puts
      end

      def banner_rows(scan)
        [
          ['Re-Anchor', scan[:reanchor_display]],
          ['Mode', scan[:mode]],
          ['Threads', scan[:options][:threads]],
          ['Timeout', scan[:options][:timeout_s]],
          ['Wordlist', scan[:options][:wdlist]],
          ['Custom Headers', Nokizaru::RequestHeaders.summary(scan[:options][:request_headers])],
          ['Allow Redirects', scan[:options][:allow_redirects]],
          ['SSL Verification', scan[:options][:verify_ssl]],
          ['Wordlist Lines', scan[:word_data][:total_lines]],
          ['Usable Entries', scan[:word_data][:unique_lines]],
          ['File Extensions', scan[:options][:filext]],
          ['Total URLs', scan[:total_urls]]
        ]
      end

      def effective_timeout_changed?(scan)
        (scan[:timeout].to_f - scan[:options][:timeout_s].to_f).abs > Float::EPSILON
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Print periodic directory scan progress updates
      def print_progress(runtime, scan, force: false)
        progress_ui = runtime[:progress_ui]
        return unless render_progress?(runtime, scan, progress_ui, force)

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        line = UI.direnum_progress(
          current: runtime[:count],
          total: scan[:total_urls],
          elapsed_s: Time.now - runtime[:start_time],
          frame_index: progress_frame_index(progress_ui, now),
          stats: {
            success: runtime[:stats][:success],
            errors: runtime[:stats][:errors],
            found: runtime[:found].length
          },
          tty: progress_output_tty?
        )

        progress_output_tty? ? print(line) : puts(line)
        progress_ui[:last_render_at] = now
        progress_ui[:last_plain_count] = runtime[:count] unless progress_output_tty?
        $stdout.flush
      end

      def render_progress?(runtime, _scan, progress_ui, force)
        return true if force
        return false if progress_output_tty? && progress_ui[:ticker_active]
        return render_tty_progress?(progress_ui) if progress_output_tty?

        (runtime[:count] - progress_ui[:last_plain_count]) >= PROGRESS_PLAIN_EVERY
      end

      def progress_frame_index(progress_ui, now)
        start = progress_ui[:started_at_mono] || now
        progress_ui[:started_at_mono] ||= start
        ((now - start) / PROGRESS_RENDER_INTERVAL_S).floor
      end

      def render_tty_progress?(progress_ui)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last = progress_ui[:last_render_at]
        last.nil? || (now - last) >= PROGRESS_RENDER_INTERVAL_S
      end

      def progress_output_tty?
        $stdout.tty?
      end

      # Clear transient progress line before printing final summary rows
      def clear_progress_line
        return unless progress_output_tty?

        print("\r\e[K")
        $stdout.flush
      end

      # Load and normalize wordlist entries used for directory enumeration
      def load_words(wdlist)
        lines = File.readlines(wdlist, chomp: true)
        normalized = lines.map(&:strip).reject(&:empty?)
        unique = normalized.uniq
        word_data(unique, lines.length)
      rescue Errno::ENOENT
        missing_wordlist(wdlist)
      rescue StandardError => e
        unreadable_wordlist(e)
      end

      def missing_wordlist(wdlist)
        UI.line(:error, "Wordlist not found : #{wdlist}")
        Log.write("[dirrec] Wordlist not found: #{wdlist}")
        empty_word_data
      end

      def unreadable_wordlist(error)
        UI.line(:error, "Failed to read wordlist : #{error.message}")
        Log.write("[dirrec] Failed to read wordlist: #{error.class} - #{error.message}")
        empty_word_data
      end

      def word_data(words, total_lines)
        {
          words: words,
          total_lines: total_lines,
          unique_lines: words.length
        }
      end

      def empty_word_data
        word_data([], 0)
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Probe the target shape quickly so we can select an enumeration mode
      def preflight_probe(target, verify_ssl:, allow_redirects:, request_headers: {})
        probe_client = build_preflight_client(
          target,
          verify_ssl: verify_ssl,
          allow_redirects: allow_redirects,
          request_headers: request_headers
        )
        metrics = empty_preflight_metrics
        run_preflight_workers(preflight_urls(target), probe_client, metrics, request_headers, allow_redirects)
        metrics
      rescue StandardError
        preflight_fallback_metrics
      ensure
        probe_client.close if probe_client.respond_to?(:close)
      end

      def build_preflight_client(target, verify_ssl:, allow_redirects:, request_headers: {})
        Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: PREFLIGHT_TIMEOUT_S,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: follow_redirects_for_client(allow_redirects, request_headers),
          verify_ssl: verify_ssl,
          max_concurrent: 8,
          retries: 0
        )
      end

      def empty_preflight_metrics
        {
          total: 0,
          errors: 0,
          timeouts: 0,
          redirects: 0,
          generic_redirects: 0,
          statuses: Hash.new(0)
        }
      end

      def preflight_fallback_metrics
        empty_preflight_metrics.merge(statuses: {})
      end

      def run_preflight_workers(urls, probe_client, metrics, request_headers, allow_redirects)
        queue = build_work_queue(urls)
        mutex = Mutex.new
        workers = Array.new(8) do
          Thread.new { preflight_worker_loop(queue, probe_client, metrics, mutex, request_headers, allow_redirects) }
        end
        workers.each(&:join)
      end

      def preflight_worker_loop(queue, probe_client, metrics, mutex, request_headers, allow_redirects)
        loop do
          url = pop_queue_url(queue)
          break if url.nil? || Nokizaru::InterruptState.interrupted?

          process_preflight_url(url, probe_client, metrics, mutex, request_headers, allow_redirects)
        end
      end

      def process_preflight_url(url, probe_client, metrics, mutex, request_headers, allow_redirects)
        result = preflight_result(probe_client, url, request_headers, allow_redirects)
        mutex.synchronize { update_preflight_metrics!(metrics, result, url) }
      rescue StandardError
        mutex.synchronize { record_preflight_error!(metrics) }
      end

      def preflight_result(probe_client, url, request_headers, allow_redirects)
        raw = request_url(probe_client, url, {
                            request_method: :head,
                            request_timeout: PREFLIGHT_TIMEOUT_S,
                            request_headers: request_headers,
                            allow_redirects: allow_redirects
                          })
        result = HttpResult.new(raw)
        { response: result, error_kind: result.success? ? nil : classify_error(result) }
      end

      def update_preflight_metrics!(metrics, result, url)
        metrics[:total] += 1
        return record_preflight_error!(metrics, result[:error_kind]) unless result[:response].success?

        record_preflight_success!(metrics, result[:response], url)
      end

      def record_preflight_error!(metrics, error_kind = nil)
        metrics[:errors] += 1
        metrics[:timeouts] += 1 if error_kind == 'timeout'
      end

      def record_preflight_success!(metrics, response, url)
        status = response.status.to_i
        metrics[:statuses][status] += 1
        return unless redirect_status?(status)

        metrics[:redirects] += 1
        sample = response_redirect_sample(response, request_url: url)
        metrics[:generic_redirects] += 1 if sample && generic_redirect_pattern?(sample[:redirect_pattern].to_s)
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Compose a small preflight set: random canaries + high-signal endpoints
      def preflight_urls(target)
        base = normalize_target_base(target)

        urls = []
        PREFLIGHT_RANDOM_PROBES.times do
          urls << "#{base}/#{SecureRandom.hex(8)}"
        end

        preflight_signal_paths.each do |path|
          urls << join_url(base, path)
        end

        urls.uniq.first(PREFLIGHT_TOTAL_PROBES)
      end

      def preflight_signal_paths
        %w[
          /robots.txt
          /sitemap.xml
          /wp-login.php
          /xmlrpc.php
          /wp-admin
          /wp-json
          /admin
          /login
        ]
      end

      # Choose enumeration mode from preflight metrics
      def choose_mode(preflight)
        total = preflight[:total].to_i
        return MODE_HOSTILE if total <= 0

        ratios = preflight_ratios(preflight, total)
        return MODE_HOSTILE if hostile_preflight?(ratios)
        return MODE_SEEDED if seeded_preflight?(ratios)

        MODE_FULL
      end

      def preflight_ratios(preflight, total)
        errors = preflight[:errors].to_i
        redirects = preflight[:redirects].to_i
        {
          success: (total - errors).to_f / total,
          error: errors.to_f / total,
          timeout: preflight[:timeouts].to_i.to_f / total,
          redirect: redirects.to_f / total,
          generic: generic_redirect_ratio(preflight, redirects)
        }
      end

      def generic_redirect_ratio(preflight, redirects)
        return 0.0 unless redirects.positive?

        preflight[:generic_redirects].to_i.to_f / redirects
      end

      def hostile_preflight?(ratios)
        severe_transport_failure = ratios[:error] >= PREFLIGHT_HOSTILE_ERROR_RATIO ||
                                   ratios[:timeout] >= PREFLIGHT_HOSTILE_TIMEOUT_RATIO
        return true if severe_transport_failure && ratios[:success] <= PREFLIGHT_HOSTILE_MIN_SUCCESS_RATIO

        return true if ratios[:timeout] >= 0.6
        return false unless ratios[:redirect] >= 0.4 && ratios[:generic] >= 0.7

        ratios[:error] >= 0.25
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def seeded_preflight?(ratios)
        return true if ratios[:redirect] >= 0.4 && ratios[:generic] >= 0.7

        return true if ratios[:error] >= PREFLIGHT_SEEDED_ERROR_RATIO

        ratios[:timeout] >= PREFLIGHT_SEEDED_TIMEOUT_RATIO
      end

      # Adjust request timeout further based on chosen mode
      def timeout_for_mode(mode, base_timeout)
        base = base_timeout.to_f
        return base if base <= 0

        case mode
        when MODE_HOSTILE
          [base, MIN_ADAPTIVE_TIMEOUT_S].min
        when MODE_SEEDED
          [base, PROTECTED_TIMEOUT_S].min
        else
          base
        end
      end

      def request_method_for_mode(_mode)
        :get
      end

      def thread_cap_for_mode(mode, threads)
        value = threads.to_i
        return [value, 1].max if mode == MODE_FULL

        cap = mode == MODE_HOSTILE ? 12 : 20
        value.clamp(1, cap)
      end

      def request_url(client, url, stop_state)
        hard_timeout = request_hard_timeout_s(stop_state)
        Timeout.timeout(hard_timeout) do
          return request_url_with_custom_headers(client, url, stop_state) if custom_request_headers?(stop_state)

          perform_client_request(client, url, stop_state)
        end
      rescue Timeout::Error
        raise Errno::ETIMEDOUT, 'directory request hard timeout reached'
      rescue NoMethodError
        client.get(url)
      end

      def custom_request_headers?(stop_state)
        Nokizaru::RequestHeaders.any?(stop_state[:request_headers])
      end

      def request_url_with_custom_headers(client, url, stop_state)
        unless stop_state[:allow_redirects]
          return perform_client_request(client, url, stop_state,
                                        headers: stop_state[:request_headers])
        end

        request_url_following_same_scope_redirects(client, url, stop_state)
      end

      def request_url_following_same_scope_redirects(client, url, stop_state)
        current = url
        redirects = 0

        loop do
          response = perform_client_request(client, current, stop_state, headers: stop_state[:request_headers])
          next_url = same_scope_redirect_url(current, response)
          return response unless next_url && redirects < Crawler::MAX_MAIN_REDIRECTS

          current = next_url
          redirects += 1
        end
      end

      def perform_client_request(client, url, stop_state, headers: nil)
        method = stop_state[:request_method].to_s
        request_headers = headers || {}

        if method == 'head' && client.respond_to?(:head)
          client.head(url, headers: request_headers)
        else
          client.get(url, headers: request_headers)
        end
      rescue ArgumentError
        if method == 'head' && client.respond_to?(:head)
          client.head(url)
        else
          client.get(url)
        end
      end

      def same_scope_redirect_url(current_url, response)
        return nil unless response.respond_to?(:status)
        return nil unless redirect_status?(response.status)

        location = response.headers['location']
        return nil if location.to_s.strip.empty?

        next_url = Nokizaru::TargetIntel.resolve_location(current_url, location)
        Nokizaru::TargetIntel.same_scope_host?(URI.parse(current_url).host, URI.parse(next_url).host) ? next_url : nil
      rescue StandardError
        nil
      end

      def request_hard_timeout_s(stop_state)
        base = stop_state.is_a?(Hash) ? stop_state[:request_timeout].to_f : 0.0
        base = MIN_ADAPTIVE_TIMEOUT_S if base <= 0
        padded = base + REQUEST_HARD_TIMEOUT_PADDING_S
        padded.clamp(REQUEST_HARD_TIMEOUT_MIN_S, REQUEST_HARD_TIMEOUT_MAX_S)
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Build full-coverage URL list with seeded paths prioritized first
      def build_scan_urls(config)
        seed_urls = build_seed_urls(config[:target], config[:ctx])
        word_urls = build_urls(config[:target], config[:words], config[:filext])
        (seed_urls + word_urls).uniq
      end

      # Build seed URLs using crawler artifacts + high-signal endpoints
      def build_seed_urls(target, ctx)
        base = normalize_target_base(target)
        paths = (high_signal_paths + seed_paths_from_crawler(ctx, base)).uniq
        paths.map { |path| join_url(base, path) }.uniq
      end

      # Extract same-scope paths from crawler module output
      def seed_paths_from_crawler(ctx, base_target)
        return [] unless ctx.respond_to?(:run)

        crawler = ctx.run.dig('modules', 'crawler')
        return [] unless crawler.is_a?(Hash)

        urls = crawler_seed_urls(crawler)
        base_uri = URI.parse(base_target)

        paths = urls.filter_map do |url|
          crawler_seed_path(url, base_uri)
        rescue StandardError
          nil
        end

        paths.uniq
      end

      def crawler_seed_urls(crawler)
        %w[internal_links robots_links urls_inside_js urls_inside_sitemap].flat_map { |key| Array(crawler[key]) }
      end

      def crawler_seed_path(url, base_uri)
        uri = URI.parse(url.to_s)
        return nil unless Nokizaru::TargetIntel.same_scope_host?(base_uri.host, uri.host)

        path = uri.path.to_s
        path = '/' if path.empty?
        return nil if path == '/'

        path
      end

      def high_signal_paths
        HIGH_SIGNAL_PATHS
      end

      def join_url(base, path)
        cleaned = path.to_s.strip
        cleaned = "/#{cleaned}" unless cleaned.start_with?('/')
        "#{normalize_target_base(base)}#{cleaned}"
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Budget stop logic
      def should_stop_now?(count, start_time, stop_state)
        return true if stop_state[:stop]

        budgets = stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
        max_requests = budgets[:max_requests].to_i
        budget_s = budgets[:budget_s].to_f

        return true if max_requests.positive? && count >= max_requests
        return true if budget_s.positive? && (Time.now - start_time) >= budget_s

        false
      end

      def stop!(stop_state, count, start_time, client = nil)
        return if stop_state[:stop]

        budgets = stop_budgets(stop_state)
        stop_state[:stop] = true
        stop_state[:reason] ||= stop_reason(budgets, count, start_time)

        close_client!(stop_state, client)
      end

      def stop_budgets(stop_state)
        stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
      end

      def stop_reason(budgets, count, start_time)
        max_requests = budgets[:max_requests].to_i
        return "request budget hit (#{count}/#{max_requests})" if max_requests.positive? && count >= max_requests

        budget_s = budgets[:budget_s].to_f
        elapsed = Time.now - start_time
        return "time budget hit (#{elapsed.round(2)}s/#{budget_s}s)" if budget_s.positive? && elapsed >= budget_s

        'stopped'
      end

      # Build candidate paths from words and optional extensions
      def build_urls(target, words, filext)
        return [] if words.empty?

        base = normalize_target_base(target)
        exts = file_extensions(filext)
        urls = exts.empty? ? base_word_urls(base, words) : extension_urls(base, words, exts)

        urls.uniq
      end

      def file_extensions(filext)
        value = filext.to_s.strip
        return [] if value.empty?

        value.split(',').map(&:strip)
      end

      def base_word_urls(base, words)
        words.map { |word| "#{base}/#{encode_path_word(word)}" }
      end

      def extension_urls(base, words, exts)
        all_exts = [''] + exts
        words.flat_map do |word|
          encoded = encode_path_word(word)
          all_exts.map { |ext| ext.empty? ? "#{base}/#{encoded}" : "#{base}/#{encoded}.#{ext}" }
        end
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Encode path words safely before constructing request URLs
      def encode_path_word(word)
        word.to_s.split('/').map { |segment| percent_encode_path_segment(segment) }.join('/')
      end

      # Encode path segments safely without converting spaces to plus signs
      def percent_encode_path_segment(segment)
        bytes = segment.to_s.b.bytes
        bytes.map do |byte|
          char = byte.chr
          if char.match?(/[A-Za-z0-9\-._~]/)
            char
          else
            format('%%%02X', byte)
          end
        end.join
      end

      # Print directory scan totals and representative findings
      def dir_output(runtime:, scan:)
        stats = runtime[:stats]
        elapsed = stats[:elapsed] || 1
        rps = ((stats[:success] + stats[:errors]) / elapsed).round(1)
        stop_meta = dir_stop_meta(runtime[:stop_state])
        stats[:confidence_context] = confidence_context_snapshot(runtime)
        result = dir_result(scan, runtime, stats, stop_meta, elapsed, rps)

        print_dir_summary(rps, runtime, stop_meta[:reason], runtime[:redirect_signals])
        store_dir_result(scan, result)
      end

      def dir_stop_meta(stop_state)
        state = stop_state || {}
        {
          mode: state[:mode].to_s,
          reason: state[:reason].to_s,
          preflight: state[:preflight],
          budgets: state[:budgets].is_a?(Hash) ? state[:budgets] : {}
        }
      end

      def dir_result(scan, runtime, stats, stop_meta, elapsed, rps)
        high_signal_found = rank_high_signal_paths(runtime[:signal_responses], scan[:normalized_target])
        found = runtime[:all_found].uniq
        prioritized_found = runtime[:found].uniq
        low_confidence_found = runtime[:low_confidence_found].uniq
        {
          'target' => {
            'original' => scan[:options][:target],
            'effective' => scan[:scan_target],
            'reanchored' => scan[:anchor][:reanchor],
            'reason' => scan[:anchor][:reason]
          },
          'found' => found,
          'raw_found' => found,
          'prioritized_found' => prioritized_found,
          'stdout_found' => runtime[:stdout_found].uniq,
          'confirmed_found' => runtime[:confirmed_found].uniq,
          'low_confidence_found' => low_confidence_found,
          'high_signal_found' => high_signal_found,
          'by_status' => grouped_response_statuses(runtime[:responses]),
          'stats' => dir_stats(stats, stop_meta, elapsed, rps)
        }
      end

      def rank_high_signal_paths(responses, normalized_target)
        Array(responses)
          .map { |url, status| [url.to_s, score_path_signal(url, status, normalized_target)] }
          .select { |(_, score)| score.positive? }
          .sort_by { |(url, score)| [-score, url.length] }
          .first(200)
          .map(&:first)
          .uniq
      end

      def score_path_signal(url, status, normalized_target)
        path = URI.parse(url).path.to_s.downcase
        target_path = URI.parse(normalized_target).path.to_s.downcase
        return 0 if path.empty? || path == '/' || path == target_path

        status_signal_score(status.to_i) + path_signal_score(path)
      rescue StandardError
        0
      end

      def status_signal_score(code)
        return 4 if [401, 403].include?(code)
        return 3 if [200, 500].include?(code)
        return 1 if [301, 302, 303, 307, 308].include?(code)

        0
      end

      def path_signal_score(path)
        score = 0
        score += 4 if high_signal_path?(path)
        score += 1 if path.count('/') >= 2
        score -= 3 if low_information_segment?(first_path_segment(path))
        score
      end

      def first_path_segment(path)
        path.to_s.split('/').reject(&:empty?).first.to_s.downcase
      end

      def high_signal_path_tokens
        @high_signal_path_tokens ||= HIGH_SIGNAL_PATHS.map { |seed| seed.delete_prefix('/').downcase }
      end

      def high_signal_path?(path)
        HIGH_SIGNAL_PATHS.any? { |seed| path_matches_seed?(path, seed.downcase) }
      end

      def path_matches_seed?(path, seed)
        path == seed || path.start_with?("#{seed}/")
      end

      def low_information_segment?(segment)
        segment.match?(/\A[a-z]{1,10}\z/) && high_signal_path_tokens.none? { |token| token.include?(segment) }
      end

      def grouped_response_statuses(responses)
        grouped = responses.group_by { |(_, status)| status.to_s }
        grouped.transform_values { |rows| rows.map(&:first) }
      end

      def dir_stats(stats, stop_meta, elapsed, rps)
        context = stats[:confidence_context] || {}
        dir_runtime_stats(stats, stop_meta, elapsed, rps)
          .merge(dir_confidence_stats(stats))
          .merge(dir_context_stats(context))
      end

      def dir_runtime_stats(stats, stop_meta, elapsed, rps)
        {
          'mode' => stop_meta[:mode],
          'stop_reason' => stop_meta[:reason].empty? ? nil : stop_meta[:reason],
          'budget_seconds' => stop_meta[:budgets][:budget_s],
          'max_requests' => stop_meta[:budgets][:max_requests],
          'preflight' => stop_meta[:preflight],
          'total_requests' => stats[:success] + stats[:errors],
          'successful' => stats[:success],
          'errors' => stats[:errors],
          'error_breakdown' => stats[:error_kinds].to_h,
          'timeout_downshifts' => stats[:timeout_downshifts].to_i,
          'elapsed_seconds' => elapsed.round(2),
          'requests_per_second' => rps
        }
      end

      def dir_confidence_stats(stats)
        {
          'confidence_levels' => stats[:confidence_levels].to_h,
          'confidence_reasons' => stats[:confidence_reasons].to_h,
          'waf_sensitive_promotion_count' => stats[:waf_sensitive_promotion_count].to_i
        }
      end

      def dir_context_stats(context)
        {
          'waf_likelihood_score' => context[:waf_likelihood_score].to_f.round(4),
          'waf_score_confidence' => context[:waf_score_confidence].to_s,
          'redirect_cluster_dominance_ratio' => context[:redirect_cluster_dominance_ratio].to_f.round(4),
          'soft_404_dominance_ratio' => context[:soft_404_dominance_ratio].to_f.round(4),
          'sensitive_status_homogeneity_ratio' => context[:sensitive_status_homogeneity_ratio].to_f.round(4),
          'sensitive_status_fingerprint_uniqueness_ratio' =>
            context[:sensitive_status_fingerprint_uniqueness_ratio].to_f.round(4),
          'context_sources_used' => Array(context[:context_sources_used]),
          'context_sources_missing' => Array(context[:context_sources_missing])
        }
      end

      def print_dir_summary(rps, runtime, stop_reason, redirect_signals)
        puts
        count_rows = redirect_signal_count_rows(redirect_signals)
        counts = dir_summary_counts(runtime)
        label_width = dir_summary_label_width(count_rows, stop_reason, counts)

        UI.row(:info, 'Requests/second', rps, label_width: label_width)
        UI.row(:info, 'Directories Found', counts[:found], label_width: label_width)
        UI.row(:info, 'Prioritized Found', counts[:prioritized], label_width: label_width)
        UI.row(:info, 'Low Confidence', counts[:low], label_width: label_width) if counts[:low].positive?
        print_redirect_signals(redirect_signals, count_rows, label_width)
        UI.row(:info, 'Stop Reason', stop_reason, label_width: label_width) unless stop_reason.to_s.strip.empty?
        puts
      end

      def dir_summary_counts(runtime)
        {
          found: runtime[:all_found].uniq.length,
          prioritized: runtime[:found].uniq.length,
          low: runtime[:low_confidence_found].uniq.length
        }
      end

      def dir_summary_label_width(count_rows, stop_reason, counts)
        labels = ['Requests/second', 'Directories Found', 'Prioritized Found']
        labels << '3xx Signals' unless count_rows.empty?
        labels << 'Low Confidence' if counts[:low].positive?
        labels << 'Stop Reason' unless stop_reason.to_s.strip.empty?
        labels.map(&:length).max
      end

      def print_redirect_signals(redirect_signals, count_rows, label_width)
        return if count_rows.empty?

        UI.row(:info, '3xx Signals', 'interesting redirects detected', label_width: label_width)
        UI.tree_rows(count_rows)

        example_rows = redirect_signal_example_rows(redirect_signals)
        return if example_rows.empty?

        UI.tree_header('3xx Examples')
        UI.tree_rows(example_rows)
      end

      def redirect_signal_count_rows(redirect_signals)
        counts = redirect_signal_counts(redirect_signals)
        rows = []
        rows << ['callback-like', counts[:callback_like]] if counts[:callback_like].positive?
        rows << ['auth-flow', counts[:auth_flow]] if counts[:auth_flow].positive?
        rows << ['cross-scope', counts[:cross_scope]] if counts[:cross_scope].positive?
        rows
      end

      def redirect_signal_example_rows(redirect_signals)
        examples = Array(redirect_signals[:examples])
        grouped = examples.group_by { |example| example[:type].to_sym }

        %i[callback_like auth_flow cross_scope].flat_map do |type|
          Array(grouped[type]).first(3).map do |example|
            [redirect_signal_label(type), redirect_signal_example_text(example)]
          end
        end
      end

      def redirect_signal_example_text(example)
        "#{example[:status]} | #{example[:request]} -> #{example[:location]}"
      end

      def redirect_signal_label(signal_type)
        case signal_type.to_sym
        when :cross_scope then 'cross-scope'
        when :callback_like then 'callback-like'
        when :auth_flow then 'auth-flow'
        else signal_type.to_s
        end
      end

      def redirect_signal_counts(redirect_signals)
        raw = redirect_signals.is_a?(Hash) ? redirect_signals[:counts] : nil
        values = raw.is_a?(Hash) ? raw : {}
        {
          cross_scope: values.fetch(:cross_scope, 0).to_i,
          callback_like: values.fetch(:callback_like, 0).to_i,
          auth_flow: values.fetch(:auth_flow, 0).to_i
        }
      end

      def store_dir_result(scan, result)
        ctx = scan[:options][:ctx]
        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
        ctx.add_artifact('prioritized_paths', result['prioritized_found']) if Array(result['prioritized_found']).any?
        ctx.add_artifact('high_signal_paths', result['high_signal_found']) if Array(result['high_signal_found']).any?
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Clamp directory enumeration timeout to reduce long-tail stalls on strict targets
      def effective_timeout_s(timeout_s, target_profile: nil, header_map: nil, allow_redirects: false)
        timeout = timeout_s.to_f
        base = if timeout.positive?
                 [timeout, MAX_EFFECTIVE_TIMEOUT_S].min
               else
                 DEFAULT_EFFECTIVE_TIMEOUT_S
               end

        return base unless protected_target?(target_profile, header_map, allow_redirects)

        [base, PROTECTED_TIMEOUT_S].min
      end

      # Detect protected edge configurations where lower timeouts preserve throughput under high challenge/error rates
      def protected_target?(target_profile, header_map, allow_redirects)
        return false if allow_redirects

        mode = target_profile_mode(target_profile)
        edge_provider?(header_map) || !mode.empty?
      end

      def target_profile_mode(target_profile)
        target_profile.is_a?(Hash) ? target_profile['mode'].to_s : ''
      end

      def edge_provider?(header_map)
        headers = header_map.is_a?(Hash) ? header_map : {}
        server = headers['server'].to_s.downcase
        powered_by = headers['x-powered-by'].to_s.downcase
        edge_vendor?(server) || powered_by.include?('cloudflare')
      end

      def edge_vendor?(server)
        %w[cloudflare akamai sucuri imperva].any? { |vendor| server.include?(vendor) }
      end

      # Decide when error profile indicates timeouts are dominating and runtime timeout should be reduced
      def should_adapt_timeout?(count, stats, timeout_state)
        return false if count < TIMEOUT_ADAPT_SAMPLE_SIZE
        return false if timeout_state[:current] <= timeout_state[:min]

        timeout_errors = stats[:error_kinds]['timeout'].to_i
        return false if timeout_errors.zero?

        (timeout_errors.to_f / count) >= TIMEOUT_ADAPT_ERROR_RATIO
      end

      # Rebuild bulk HTTP client with lower timeout to keep directory scan throughput stable on protected targets
      def rebuild_client_with_lower_timeout(config)
        client = config[:client]
        timeout_state = config[:timeout_state]
        next_timeout = next_timeout_value(timeout_state)
        return [client, timeout_state] if next_timeout >= timeout_state[:current]

        refreshed = rebuild_client_with_timeout(config, next_timeout)

        [refreshed, timeout_state.merge(current: next_timeout)]
      rescue StandardError
        [client, timeout_state]
      end

      def next_timeout_value(timeout_state)
        [(timeout_state[:current] * 0.6).round(2), timeout_state[:min]].max
      end

      def rebuild_client(config)
        client = config[:client]
        timeout_state = config[:timeout_state]
        refreshed = rebuild_client_with_timeout(config, timeout_state[:current].to_f)
        [refreshed, timeout_state]
      rescue StandardError
        [client, timeout_state]
      end

      def rebuild_client_with_timeout(config, timeout)
        config[:client].close if config[:client].respond_to?(:close)
        Nokizaru::HTTPClient.for_bulk_requests(
          config[:target],
          timeout_s: timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: follow_redirects_for_client(config[:allow_redirects], config[:request_headers]),
          verify_ssl: config[:verify_ssl],
          max_concurrent: [config[:threads].to_i, 1].max,
          retries: 0
        )
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Downgrade scan mode during execution if the target becomes hostile under load
      def apply_mode_downgrade!(count, stats, stop_state, timeout_state)
        return nil if stop_state[:stop]
        return nil if count < 80

        current_mode = stop_state[:mode].to_s
        return nil if current_mode == MODE_HOSTILE

        if current_mode == MODE_FULL && low_signal_saturation?(count, stats)
          return apply_seeded_mode!(stop_state, timeout_state)
        end

        return nil unless hostile_runtime_ratios?(count, stats)

        apply_hostile_mode!(stop_state, timeout_state)
      end

      def low_signal_saturation?(count, stats)
        return false if count < 160

        positive_statuses = stats[:positive_statuses].is_a?(Hash) ? stats[:positive_statuses] : {}
        positive_total = positive_statuses.values.sum
        return false if positive_total < 60

        dominant = positive_statuses[200].to_i + positive_statuses[401].to_i + positive_statuses[403].to_i
        positive_ratio = positive_total.to_f / count
        dominant_ratio = dominant.to_f / positive_total
        positive_ratio >= 0.32 && dominant_ratio >= 0.9
      end

      def hostile_runtime_ratios?(count, stats)
        errors = stats[:errors].to_i
        timeouts = stats[:error_kinds]['timeout'].to_i
        (timeouts.to_f / count) >= 0.08 || (errors.to_f / count) >= 0.75
      end

      def apply_hostile_mode!(stop_state, timeout_state)
        stop_state[:mode] = MODE_HOSTILE
        stop_state[:budgets] = MODE_BUDGETS.fetch(MODE_HOSTILE)
        stop_state[:request_method] = request_method_for_mode(MODE_HOSTILE)
        timeout_state[:current] = timeout_for_mode(MODE_HOSTILE, timeout_state[:current])
        stop_state[:request_timeout] = timeout_state[:current]
        :downgraded
      end

      def apply_seeded_mode!(stop_state, timeout_state)
        stop_state[:mode] = MODE_SEEDED
        stop_state[:budgets] = MODE_BUDGETS.fetch(MODE_SEEDED)
        stop_state[:request_method] = request_method_for_mode(MODE_SEEDED)
        timeout_state[:current] = timeout_for_mode(MODE_SEEDED, timeout_state[:current])
        stop_state[:request_timeout] = timeout_state[:current]
        :downgraded
      end

      def close_client!(stop_state, client)
        return unless client
        return if stop_state[:client_closed]

        stop_state[:client_closed] = true
        client.close if client.respond_to?(:close)
      rescue StandardError
        nil
      end

      # Group transport failures so adaptive timeout logic can react to dominant failure classes
      def classify_error(http_result)
        error = http_result.error
        message = http_result.error_message.to_s.downcase

        return 'timeout' if timeout_error?(message, error)
        return 'tls' if defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
        return 'connection' if connection_error_message?(message)

        'other'
      end

      def timeout_error?(message, error)
        timeout_message?(message) || timeout_exception?(error)
      end

      def timeout_message?(message)
        message.include?('timeout') || message.include?('timed out') ||
          message.include?('waiting on select') || message.include?('waited')
      end

      def timeout_exception?(error)
        timeout_error_classes.any? { |klass| klass && error.is_a?(klass) }
      end

      def timeout_error_classes
        [
          (defined?(Timeout::Error) ? Timeout::Error : nil),
          (defined?(Errno::ETIMEDOUT) ? Errno::ETIMEDOUT : nil),
          (defined?(IO::TimeoutError) ? IO::TimeoutError : nil),
          (defined?(HTTPX::TimeoutError) ? HTTPX::TimeoutError : nil)
        ]
      end

      def connection_error_message?(message)
        message.include?('connection') || message.include?('reset') || message.include?('refused')
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Detect wildcard or soft-404 responses so noisy 200 pages are filtered
      def build_soft_404_baseline(client, target, request_headers: {}, allow_redirects: false,
                                  request_timeout: PREFLIGHT_TIMEOUT_S)
        samples = []
        SOFT_404_PROBES.times do
          sample = soft_404_probe_sample(
            client,
            target,
            request_headers: request_headers,
            allow_redirects: allow_redirects,
            request_timeout: request_timeout
          )
          samples << sample if sample
        rescue StandardError
          nil
        end

        soft_404_baseline_from_samples(samples)
      end

      def soft_404_probe_sample(client, target, request_headers:, allow_redirects:, request_timeout:)
        probe_url = "#{normalize_target_base(target)}/#{SecureRandom.hex(10)}"
        raw = request_url(client, probe_url, {
                            request_method: :get,
                            request_timeout: request_timeout,
                            request_headers: request_headers,
                            allow_redirects: allow_redirects
                          })
        result = HttpResult.new(raw)
        return nil unless result.success?

        response_sample(result, request_url: probe_url)
      end

      # Build a compact comparable sample from one HTTP response
      def response_sample(http_result, request_url: nil)
        status = http_result.status.to_i
        return nil unless SOFT_404_SAMPLE_STATUSES.include?(status)

        context = response_sample_context(http_result, request_url)
        response_sample_payload(status, context)
      end

      def response_sample_payload(status, context)
        {
          status: status,
          content_type: context[:content_type],
          body_length: context[:body].bytesize
        }.merge(response_sample_body_fields(context)).merge(
          location: context[:location],
          redirect_pattern: context[:pattern]
        )
      end

      def response_sample_body_fields(context)
        {
          title: extract_title(context[:body]),
          fingerprint: body_fingerprint(context[:body])
        }
      end

      def response_sample_context(http_result, request_url)
        {
          content_type: normalize_content_type(http_result.headers['content-type']),
          body: http_result.body.to_s,
          location: normalized_location_from_request(request_url, http_result.headers['location']),
          pattern: redirect_pattern(request_url, http_result.headers['location'])
        }
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Build a lightweight redirect sample used by directory redirect fast-path filtering
      def response_redirect_sample(http_result, request_url: nil)
        status = http_result.status.to_i
        return nil unless redirect_status?(status)

        location = normalized_location_from_request(request_url, http_result.headers['location'])
        pattern = redirect_pattern(request_url, http_result.headers['location'])
        {
          status: status,
          location: location,
          redirect_pattern: pattern
        }
      end

      # Compute a soft-404 baseline from probe samples when they are consistent
      def soft_404_baseline_from_samples(samples)
        return nil if samples.length < SOFT_404_MIN_PROBES

        status = single_soft_404_status(samples)
        return nil unless status
        return redirect_soft_404_baseline(samples, status) if redirect_status?(status)

        content_soft_404_baseline(samples, status)
      end

      def single_soft_404_status(samples)
        statuses = samples.map { |sample| sample[:status] }.uniq
        return nil unless statuses.length == 1

        statuses.first
      end

      def redirect_soft_404_baseline(samples, status)
        patterns = samples.map { |sample| sample[:redirect_pattern] }.compact.uniq
        return { status: status, redirect_pattern: patterns.first } if patterns.length == 1

        locations = samples.map { |sample| sample[:location] }.compact.uniq
        return nil unless locations.length == 1

        { status: status, location: locations.first }
      end

      def content_soft_404_baseline(samples, status)
        content_type = single_content_type(samples)
        return nil unless content_type

        median_length = median_body_length(samples)
        return nil unless median_length

        content_baseline_payload(samples, status, content_type, median_length)
      end

      def content_baseline_payload(samples, status, content_type, median_length)
        {
          status: status,
          content_type: content_type,
          body_length: median_length,
          tolerance: soft_404_tolerance(median_length),
          title: single_sample_title(samples),
          fingerprint: single_sample_fingerprint(samples)
        }
      end

      def single_content_type(samples)
        content_types = samples.map { |sample| sample[:content_type] }.uniq
        content_types.length == 1 ? content_types.first : nil
      end

      def median_body_length(samples)
        lengths = samples.map { |sample| sample[:body_length] }
        return nil if lengths.empty?

        lengths.sort[lengths.length / 2]
      end

      def soft_404_tolerance(body_length)
        [(body_length * 0.05).round, SOFT_404_MIN_TOLERANCE].max.clamp(0, SOFT_404_MAX_TOLERANCE)
      end

      def single_sample_title(samples)
        titles = samples.map { |sample| sample[:title] }.uniq
        titles.length == 1 ? titles.first : nil
      end

      def single_sample_fingerprint(samples)
        fingerprints = samples.map { |sample| sample[:fingerprint] }.compact
        fingerprints.uniq.length == 1 ? fingerprints.first : nil
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Check whether a response matches wildcard baseline signature
      def soft_404_match?(http_result, baseline)
        sample = response_sample(http_result)
        soft_404_match_sample?(sample, baseline)
      end

      # Check whether a precomputed response sample matches wildcard baseline
      def soft_404_match_sample?(sample, baseline)
        return false unless valid_soft_404_sample?(sample, baseline)
        return redirect_soft_404_match?(sample, baseline) if redirect_status?(sample[:status])
        return false unless sample[:content_type] == baseline[:content_type]
        return true if fingerprint_match?(sample, baseline)

        title_and_length_match?(sample, baseline)
      end

      def valid_soft_404_sample?(sample, baseline)
        baseline && sample && sample[:status] == baseline[:status]
      end

      def redirect_soft_404_match?(sample, baseline)
        return sample[:redirect_pattern] == baseline[:redirect_pattern] if baseline[:redirect_pattern]
        return false unless baseline[:location]

        sample[:location] == baseline[:location]
      end

      def fingerprint_match?(sample, baseline)
        baseline_fingerprint = baseline[:fingerprint]
        sample_fingerprint = sample[:fingerprint]
        baseline_fingerprint && sample_fingerprint && baseline_fingerprint == sample_fingerprint
      end

      def title_and_length_match?(sample, baseline)
        length_delta = (sample[:body_length] - baseline[:body_length]).abs
        return false if length_delta > baseline[:tolerance]
        return true unless baseline[:title]

        sample[:title] == baseline[:title]
      end

      def finding_confidence(url, status, sample, baseline, normalized_target)
        return confidence_decision(:low, :soft_404_signature_match) if soft_404_match_sample?(sample, baseline)

        case status.to_i
        when 401, 403, 405, 500
          sensitive_status_confidence(url, sample, baseline, normalized_target, status.to_i)
        when 301, 302, 303, 307, 308
          redirect_confidence(url, sample, normalized_target)
        when 200, 204
          content_confidence(url, sample, baseline, normalized_target)
        else
          confidence_decision(:low, :non_actionable_status)
        end
      end

      def redirect_confidence(url, sample, normalized_target)
        path = response_path(url)
        return confidence_decision(:confirmed, :high_signal_path) if high_signal_path?(path)

        if sample.to_h[:redirect_pattern].to_s.start_with?('auth_entry:')
          return confidence_decision(:confirmed,
                                     :auth_redirect)
        end
        if generic_redirect_pattern?(sample.to_h[:redirect_pattern].to_s)
          return confidence_decision(:low,
                                     :generic_redirect_pattern)
        end
        return confidence_decision(:low, :target_root_redirect) if same_path_as_target?(path, normalized_target)

        confidence_decision(:likely, :path_specific_redirect)
      end

      def sensitive_status_confidence(url, sample, baseline, normalized_target, status)
        path = response_path(url)
        return confidence_decision(:confirmed, :high_signal_path) if high_signal_path?(path)
        return confidence_decision(:low, :target_root_sensitive_status) if same_path_as_target?(path, normalized_target)
        return confidence_decision(:low, :baseline_like_response) if baseline_like_length?(sample, baseline)
        return confidence_decision(:likely, :meaningful_sensitive_status) if meaningful_body?(sample)
        return confidence_decision(:low, :weak_sensitive_status) if weak_sensitive_status_sample?(path, sample, status)

        confidence_decision(:likely, :sensitive_status)
      end

      def content_confidence(url, sample, baseline, normalized_target)
        path = response_path(url)
        return confidence_decision(:low, :baseline_like_response) if baseline_like_length?(sample, baseline)
        return confidence_decision(:low, :not_found_title) if likely_not_found_title?(sample)

        if high_signal_path?(path) && meaningful_body?(sample)
          return confidence_decision(:confirmed,
                                     :high_signal_content)
        end
        return confidence_decision(:likely, :meaningful_content) if meaningful_body?(sample)
        if high_signal_path?(path) && !same_path_as_target?(path, normalized_target)
          return confidence_decision(:likely, :high_signal_path)
        end

        confidence_decision(:low, :low_information_response)
      end

      def confidence_decision(level, reason)
        {
          level: level.to_sym,
          reason: reason.to_s
        }
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      def sensitive_status_reason?(reason)
        %w[sensitive_status meaningful_sensitive_status].include?(reason.to_s)
      end

      def init_confidence_context(scan)
        {
          counters: {
            total_candidates: 0,
            soft_404_matches: 0,
            redirect_total: 0,
            redirect_patterns: Hash.new(0),
            sensitive_total: 0,
            sensitive_status_counts: Hash.new(0),
            sensitive_fingerprints: Hash.new(0)
          },
          enrichment: context_enrichment(scan),
          snapshot: nil
        }
      end

      def context_enrichment(scan)
        ctx = scan[:options][:ctx]
        modules = ctx.respond_to?(:run) ? ctx.run.fetch('modules', {}) : {}
        headers = modules['headers'].is_a?(Hash) ? modules['headers'] : {}
        crawler = modules['crawler'].is_a?(Hash) ? modules['crawler'] : {}
        wayback = modules['wayback'].is_a?(Hash) ? modules['wayback'] : {}

        hints = {
          headers_edge_hint: edge_header_hint?(headers),
          crawler_blocked_hint: crawler_blocked_hint?(crawler),
          crawler_low_unique_hint: crawler_low_unique_hint?(crawler),
          wayback_heavy_hint: wayback_heavy_hint?(wayback, crawler)
        }

        {
          hints: hints,
          sources_used: hints.select { |_, value| value }.keys.map(&:to_s),
          sources_missing: %w[headers_edge_hint crawler_blocked_hint crawler_low_unique_hint wayback_heavy_hint] -
            hints.select { |_, value| value }.keys.map(&:to_s)
        }
      end

      def edge_header_hint?(headers_module)
        map = headers_module['headers'].is_a?(Hash) ? headers_module['headers'] : {}
        server = map['server'].to_s.downcase
        powered = map['x-powered-by'].to_s.downcase
        challenge = map['cf-mitigated'].to_s.downcase
        edge_vendor?(server) || powered.include?('cloudflare') || challenge == 'challenge'
      end

      def crawler_blocked_hint?(crawler_module)
        crawler_module['error'].to_s.match?(/HTTP status (403|405|429)\b/)
      end

      def crawler_low_unique_hint?(crawler_module)
        stats = crawler_module['stats'].is_a?(Hash) ? crawler_module['stats'] : {}
        stats['total_unique'].to_i.positive? && stats['total_unique'].to_i < 20
      end

      def wayback_heavy_hint?(wayback_module, crawler_module)
        urls = Array(wayback_module['urls']).length
        stats = crawler_module['stats'].is_a?(Hash) ? crawler_module['stats'] : {}
        urls >= 500 && stats['total_unique'].to_i < 50
      end

      def update_confidence_context!(runtime, status, sample, baseline, _decision)
        ctx = runtime[:confidence_context]
        counters = ctx[:counters]
        counters[:total_candidates] += 1
        counters[:soft_404_matches] += 1 if soft_404_match_sample?(sample, baseline)

        update_redirect_context!(counters, status, sample)
        update_sensitive_status_context!(counters, status, sample)

        ctx[:snapshot] = nil
      end

      def update_redirect_context!(counters, status, sample)
        return unless redirect_status?(status)

        counters[:redirect_total] += 1
        pattern = sample.to_h[:redirect_pattern].to_s
        return if pattern.empty?

        counters[:redirect_patterns][pattern] += 1
      end

      def update_sensitive_status_context!(counters, status, sample)
        return unless [401, 403, 405, 500].include?(status.to_i)

        counters[:sensitive_total] += 1
        counters[:sensitive_status_counts][status.to_i] += 1
        fingerprint = sample.to_h[:fingerprint].to_s
        return if fingerprint.empty?

        counters[:sensitive_fingerprints][fingerprint] += 1
      end

      def confidence_context_snapshot(runtime)
        cached = runtime.dig(:confidence_context, :snapshot)
        return cached if cached

        ctx = runtime[:confidence_context]
        counters = ctx[:counters]
        enrichment = ctx[:enrichment]

        redirect_cluster = redirect_cluster_dominance_ratio(counters)
        soft_404_dominance = ratio(counters[:soft_404_matches], counters[:total_candidates])
        sensitive_homogeneity = sensitive_status_homogeneity_ratio(counters)
        sensitive_uniqueness = sensitive_status_fingerprint_uniqueness_ratio(counters)
        waf_score = waf_likelihood_score(
          redirect_cluster,
          soft_404_dominance,
          sensitive_homogeneity,
          sensitive_uniqueness,
          enrichment[:hints]
        )

        snapshot = {
          waf_likelihood_score: waf_score,
          waf_score_confidence: waf_score_confidence(counters[:total_candidates]),
          redirect_cluster_dominance_ratio: redirect_cluster,
          soft_404_dominance_ratio: soft_404_dominance,
          sensitive_status_homogeneity_ratio: sensitive_homogeneity,
          sensitive_status_fingerprint_uniqueness_ratio: sensitive_uniqueness,
          context_sources_used: enrichment[:sources_used],
          context_sources_missing: enrichment[:sources_missing]
        }

        runtime[:confidence_context][:snapshot] = snapshot
      end

      def redirect_cluster_dominance_ratio(counters)
        total = counters[:redirect_total].to_i
        return 0.0 if total <= 0

        max_cluster = counters[:redirect_patterns].values.max.to_i
        ratio(max_cluster, total)
      end

      def sensitive_status_homogeneity_ratio(counters)
        total = counters[:sensitive_total].to_i
        return 0.0 if total <= 0

        ratio(counters[:sensitive_status_counts].values.max.to_i, total)
      end

      def sensitive_status_fingerprint_uniqueness_ratio(counters)
        total = counters[:sensitive_total].to_i
        return 0.0 if total <= 0

        ratio(counters[:sensitive_fingerprints].keys.length, total)
      end

      def waf_likelihood_score(redirect_cluster, soft_404_dominance, sensitive_homogeneity, sensitive_uniqueness, hints)
        enrichment = hints.values.count(true).fdiv([hints.length, 1].max)
        score =
          (redirect_cluster * 0.35) +
          (soft_404_dominance * 0.30) +
          (sensitive_homogeneity * 0.20) +
          ((1.0 - sensitive_uniqueness) * 0.10) +
          (enrichment * 0.05)
        score.clamp(0.0, 1.0)
      end

      def waf_score_confidence(total_candidates)
        count = total_candidates.to_i
        return 'high' if count >= 500
        return 'medium' if count >= 100

        'low'
      end

      def ratio(numerator, denominator)
        return 0.0 if denominator.to_f <= 0.0

        numerator.to_f / denominator
      end

      def apply_waf_confidence_adjustment(decision, _status, _sample, url, _normalized_target, context)
        return decision if decision[:level].to_sym == :low
        return decision unless context[:waf_likelihood_score].to_f >= WAF_LIKELIHOOD_HIGH

        if waf_sensitive_status_noise?(decision, context)
          return confidence_decision(downgraded_confidence_level(decision[:level]), :waf_sensitive_status_homogeneity)
        end

        if waf_redirect_cluster_noise?(decision, context, url)
          return confidence_decision(downgraded_confidence_level(decision[:level]), :waf_redirect_cluster_dominance)
        end

        decision
      end

      def waf_sensitive_status_noise?(decision, context)
        sensitive_status_reason?(decision[:reason]) &&
          context[:sensitive_status_homogeneity_ratio].to_f >= WAF_SENSITIVE_HOMOGENEITY &&
          context[:sensitive_status_fingerprint_uniqueness_ratio].to_f <= WAF_SENSITIVE_UNIQUENESS_LOW
      end

      def waf_redirect_cluster_noise?(decision, context, url)
        decision[:reason].to_s == 'path_specific_redirect' &&
          context[:redirect_cluster_dominance_ratio].to_f >= WAF_REDIRECT_CLUSTER_DOMINANCE &&
          context[:soft_404_dominance_ratio].to_f >= SOFT_404_MIN_DOMINANCE_RATIO &&
          !high_signal_path?(response_path(url))
      end

      def downgraded_confidence_level(level)
        case level.to_sym
        when :confirmed then :likely
        else :low
        end
      end

      def response_path(url)
        URI.parse(url.to_s).path.to_s.downcase
      rescue StandardError
        ''
      end

      def same_path_as_target?(path, normalized_target)
        return true if path.to_s.empty? || path == '/'

        target_path = URI.parse(normalized_target.to_s).path.to_s.downcase
        target_path = '/' if target_path.empty?
        normalize_pattern_path(path) == normalize_pattern_path(target_path)
      rescue StandardError
        false
      end

      def meaningful_body?(sample)
        payload = sample.to_h
        return false unless textual_content?(payload[:content_type])

        payload[:body_length].to_i > LOW_INFORMATION_BODY_BYTES
      end

      def textual_content?(content_type)
        type = content_type.to_s.downcase
        TEXTUAL_CONTENT_TYPES.any? { |token| type.start_with?(token) }
      end

      def baseline_like_length?(sample, baseline)
        return false unless sample && baseline
        return false unless sample[:content_type] == baseline[:content_type]

        tolerance = baseline[:tolerance].to_i
        return false unless tolerance.positive?

        (sample[:body_length].to_i - baseline[:body_length].to_i).abs <= [tolerance / 2, 64].max
      end

      def likely_not_found_title?(sample)
        title = sample.to_h[:title].to_s
        return false if title.empty?

        title.include?('not found') || title.include?('404')
      end

      def weak_sensitive_status_sample?(path, sample, status)
        return false unless [401, 403, 405, 500].include?(status.to_i)

        payload = sample.to_h
        generic_body = payload[:body_length].to_i <= (LOW_INFORMATION_BODY_BYTES * 2)
        generic_title = payload[:title].to_s.strip.empty?
        low_signal_segment = low_information_segment?(first_path_segment(path))
        generic_body && generic_title && low_signal_segment
      end

      # Initialize dynamic baseline learner for strict targets with generic 200 pages
      def init_soft_404_learning
        { total: 0, signatures: Hash.new(0), samples: {} }
      end

      # Track baseline learning state so expensive response matching can be disabled when ineffective
      def init_soft_404_state
        { enabled: true, sampled: 0 }
      end

      # Check whether soft-404 logic should run for current response handling
      def soft_404_active?(state, baseline)
        return false unless state[:enabled]
        return true if baseline

        state[:sampled] < SOFT_404_MAX_LEARNING_SAMPLES
      end

      # Record one sampled response considered for wildcard baseline learning
      def record_soft_404_sample!(state)
        state[:sampled] += 1
      end

      # Disable soft-404 matching when learning remains unstable after enough samples
      def disable_soft_404_if_unstable!(state, baseline, learning)
        return if baseline
        return if state[:sampled] < SOFT_404_MIN_LEARNING_SAMPLES
        return if learning_top_ratio(learning) >= SOFT_404_MIN_DOMINANCE_RATIO

        state[:enabled] = false
      end

      # Return dominant signature ratio to decide if a wildcard baseline is likely
      def learning_top_ratio(learning)
        total = learning[:total].to_i
        return 0.0 if total <= 0

        top_count = learning[:signatures].values.max.to_i
        top_count.to_f / total
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Learn a fallback baseline from repeated response signatures during enumeration
      def learn_soft_404_baseline(sample, baseline, learning)
        return baseline if baseline || sample.nil?
        return baseline unless SOFT_404_SAMPLE_STATUSES.include?(sample[:status])

        signature_key = sample_signature_key(sample)
        return baseline unless signature_key

        update_learning_signature!(learning, sample, signature_key)
        promoted = promote_learning_signature(learning)
        return baseline unless promoted

        promoted_soft_404_baseline(promoted)
      end

      def sample_signature_key(sample)
        if redirect_status?(sample[:status])
          sample[:redirect_pattern] || sample[:location]
        else
          sample[:fingerprint] || sample[:title]
        end
      end

      def update_learning_signature!(learning, sample, signature_key)
        learning[:total] += 1
        signature = [sample[:status], sample[:content_type], signature_key, sample[:body_length] / 256]
        learning[:signatures][signature] += 1
        learning[:samples][signature] ||= sample
        signature
      end

      def promote_learning_signature(learning)
        top_signature, top_count = learning[:signatures].max_by { |_signature, count| count }
        return nil unless top_signature && learning[:total] >= 8
        return nil unless top_count >= 6
        return nil unless (top_count.to_f / learning[:total]) >= 0.8

        learning[:samples][top_signature]
      end

      def promoted_soft_404_baseline(sample)
        return promoted_redirect_baseline(sample) if redirect_status?(sample[:status])

        {
          status: sample[:status],
          content_type: sample[:content_type],
          body_length: sample[:body_length],
          tolerance: soft_404_tolerance(sample[:body_length]),
          title: sample[:title],
          fingerprint: sample[:fingerprint]
        }
      end

      def promoted_redirect_baseline(sample)
        {
          status: sample[:status],
          location: sample[:location],
          redirect_pattern: sample[:redirect_pattern]
        }
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Build a stable body fingerprint for generic wildcard pages with minor dynamic values
      def body_fingerprint(body)
        raw = body.to_s
        return nil if raw.empty?

        slice = if raw.bytesize <= 2048
                  raw
                else
                  "#{raw.byteslice(0, 1024)}#{raw.byteslice(-1024, 1024)}"
                end

        normalized = slice.downcase.gsub(/[a-f0-9]{8,}/i, '#').gsub(/\d+/, '#').gsub(/\s+/, ' ').strip
        return nil if normalized.empty?

        Zlib.crc32(normalized).to_s(16)
      end

      # Normalize content type so comparisons ignore charset variations
      def normalize_content_type(content_type)
        content_type.to_s.split(';', 2).first.to_s.strip.downcase
      end

      # Normalize location for wildcard redirect matching while ignoring dynamic query strings
      def normalize_location(location)
        value = location.to_s.strip
        return nil if value.empty?

        uri = URI.parse(value)
        path = uri.path.to_s
        path = '/' if path.empty?
        host = uri.host.to_s.downcase
        return path if host.empty?

        "#{host}#{path}"
      rescue URI::InvalidURIError
        value.split('?', 2).first
      end

      # Normalize request target to avoid duplicated path separators during URL generation
      def normalize_target_base(target)
        value = target.to_s.strip
        return value if value.empty?

        value.end_with?('/') ? value.chomp('/') : value
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Resolve and normalize redirect location using request context when available
      def normalized_location_from_request(request_url, location_header)
        value = location_header.to_s.strip
        return nil if value.empty?

        resolved = if request_url.to_s.strip.empty?
                     value
                   else
                     Nokizaru::TargetIntel.resolve_location(request_url, value)
                   end

        normalize_location(resolved)
      end

      def redirect_signal_type(request_url, http_result)
        location_header = http_result.headers['location'].to_s
        return nil if location_header.strip.empty?

        resolved = Nokizaru::TargetIntel.resolve_location(request_url, location_header)
        return :cross_scope if cross_scope_redirect?(request_url, resolved)
        return :callback_like if callback_like_redirect?(location_header, resolved)

        pattern = redirect_pattern(request_url, location_header)
        return :auth_flow if pattern.to_s.start_with?('auth_entry:')

        nil
      rescue StandardError
        nil
      end

      def cross_scope_redirect?(request_url, resolved_location)
        req = URI.parse(request_url.to_s)
        loc = URI.parse(resolved_location.to_s)
        return false if req.host.to_s.empty? || loc.host.to_s.empty?

        !Nokizaru::TargetIntel.same_scope_host?(req.host, loc.host)
      rescue StandardError
        false
      end

      def callback_like_redirect?(location_header, resolved_location)
        value = [location_header, resolved_location].compact.join(' ').downcase
        return false if value.empty?

        callback_tokens.any? { |token| value.include?(token) }
      end

      def callback_tokens
        @callback_tokens ||= %w[callback redirect_uri return next continue destination dest oauth state code
                                verifier].freeze
      end

      def push_redirect_example(examples, signal_type, status, request_url, http_result)
        return if examples.count { |entry| entry[:type].to_sym == signal_type.to_sym } >= 3

        location = http_result.headers['location'].to_s.strip
        return if location.empty?

        examples << {
          type: signal_type,
          status: status.to_i,
          request: summarize_redirect_url(request_url),
          location: summarize_redirect_url(location)
        }
      end

      def summarize_redirect_url(url)
        value = url.to_s.strip
        return value if value.length <= 80

        "#{value[0, 77]}..."
      end

      # Build a generic redirect pattern so path-preserving redirects can be recognized as one behavior class
      def redirect_pattern(request_url, location_header)
        req = URI.parse(request_url.to_s)
        resolved = Nokizaru::TargetIntel.resolve_location(request_url, location_header)
        loc = URI.parse(resolved)
        return nil unless Nokizaru::TargetIntel.same_scope_host?(req.host, loc.host)

        req_path = normalize_pattern_path(req.path)
        loc_path = normalize_pattern_path(loc.path)
        redirect_pattern_for_paths(req_path, loc_path, loc)
      rescue StandardError
        nil
      end

      def redirect_pattern_for_paths(req_path, loc_path, loc)
        scheme_host = "#{loc.scheme}:#{loc.host.to_s.downcase}"
        return "same_path:#{scheme_host}" if req_path == loc_path
        return "same_path_slash:#{scheme_host}" if same_path_slash?(req_path, loc_path)
        return "root:#{scheme_host}" if loc_path == '/'
        return "auth_entry:#{scheme_host}" if loc_path.start_with?('/login', '/signin', '/auth')

        "path_specific:#{scheme_host}:#{loc_path}"
      end

      def same_path_slash?(req_path, loc_path)
        "#{req_path}/" == loc_path || (req_path == '/' && loc_path == '/')
      end

      # Normalize path for redirect pattern comparisons while preserving root
      def normalize_pattern_path(path)
        value = path.to_s
        value = '/' if value.empty?
        return '/' if value == '/'

        value.chomp('/')
      end
    end
  end
end

module Nokizaru
  module Modules
    # Nokizaru::Modules::DirectoryEnum implementation
    module DirectoryEnum
      module_function

      # Generic redirect patterns are likely anti-enumeration normalizers unless they diverge from baseline
      def generic_redirect_pattern?(pattern)
        pattern.start_with?('same_path:', 'same_path_slash:', 'root:', 'auth_entry:')
      end

      # Check whether status code represents an HTTP redirect response
      def redirect_status?(status)
        REDIRECT_STATUSES.include?(status.to_i)
      end

      # Apply tiny per-worker backoff on sustained errors to improve useful throughput under strict targets
      def error_backoff_s(error_streak, mode = nil)
        return 0.0 if mode.to_s == MODE_HOSTILE

        streak = error_streak.to_i
        return 0.0 if streak < 4

        [((streak - 3) * 0.01), 0.05].min
      end

      # Extract and normalize title text for lightweight HTML similarity checks
      def extract_title(body)
        match = body.match(%r{<title[^>]*>(.*?)</title>}im)
        return nil unless match

        title = match[1].to_s.gsub(/\s+/, ' ').strip.downcase
        title.empty? ? nil : title
      end
    end
  end
end
