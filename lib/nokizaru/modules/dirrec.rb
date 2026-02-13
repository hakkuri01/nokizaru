# frozen_string_literal: true

require 'set'
require 'securerandom'
require 'zlib'
require 'uri'

require_relative '../http_client'
require_relative '../http_result'
require_relative '../log'
require_relative '../target_intel'

module Nokizaru
  module Modules
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
      PROGRESS_EVERY = 200
      PROTECTED_TIMEOUT_S = 2.5
      MIN_ADAPTIVE_TIMEOUT_S = 1.5
      TIMEOUT_ADAPT_SAMPLE_SIZE = 240
      TIMEOUT_ADAPT_ERROR_RATIO = 0.2
      PREFLIGHT_RANDOM_PROBES = 6
      PREFLIGHT_TOTAL_PROBES = 12
      PREFLIGHT_TIMEOUT_S = 1.5

      MODE_FULL = 'full'
      MODE_SEEDED = 'seeded'
      MODE_HOSTILE = 'hostile'

      MODE_BUDGETS = {
        MODE_FULL => { budget_s: 45.0, max_requests: 5000 },
        MODE_SEEDED => { budget_s: 18.0, max_requests: 600 },
        MODE_HOSTILE => { budget_s: 10.0, max_requests: 220 }
      }.freeze
      REDIRECT_STATUSES = Set[301, 302, 303, 307, 308].freeze
      SOFT_404_SAMPLE_STATUSES = Set[200, 204, 301, 302, 303, 307, 308, 401, 403, 405, 500].freeze

      INTERESTING_STATUSES = Set[200, 204, 301, 302, 303, 307, 308, 401, 403, 405, 500].freeze

      # Run this module and store normalized results in the run context
      def call(target, threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, ctx)
        anchor = resolve_anchor(target, ctx, verify_ssl, timeout_s)
        scan_target = anchor[:effective_target]
        header_map = ctx.run.dig('modules', 'headers', 'headers')
        reanchor_display = "#{scan_target} (#{anchor[:reason_code]})"

        normalized_target = normalize_target_base(scan_target)
        word_data = load_words(wdlist)
        words = word_data[:words]

        base_timeout = effective_timeout_s(timeout_s, target_profile: anchor[:profile], header_map: header_map,
                                                      allow_redirects: allow_redirects)

        preflight = preflight_probe(
          normalized_target,
          verify_ssl: verify_ssl,
          allow_redirects: allow_redirects
        )
        mode = choose_mode(preflight)
        budgets = MODE_BUDGETS.fetch(mode)
        effective_timeout = timeout_for_mode(mode, base_timeout)

        urls = build_scan_urls(
          mode,
          normalized_target,
          words,
          filext,
          ctx,
          max_seed_paths: budgets[:max_requests]
        )
        total = urls.length

        print_banner(reanchor_display, mode, threads, timeout_s, effective_timeout, wdlist, allow_redirects, verify_ssl,
                     filext, word_data, total)

        # Thread-safe result storage
        mutex = Mutex.new
        responses = []
        found = []
        stats = {
          success: 0,
          errors: 0,
          filtered: 0,
          redirect_filtered: 0,
          redirect_outliers: 0,
          timeout_downshifts: 0,
          error_kinds: Hash.new(0)
        }
        count = 0
        timeout_state = { current: effective_timeout, min: MIN_ADAPTIVE_TIMEOUT_S }
        stop_state = {
          stop: false,
          reason: nil,
          mode: mode,
          budgets: budgets,
          preflight: preflight,
          request_method: request_method_for_mode(mode),
          client_closed: false
        }

        # Create worker threads
        num_workers = [thread_cap_for_mode(mode, threads.to_i), 1].max
        start_time = Time.now

        # Build one shared client - all workers use this same client
        # Connection pooling happens automatically inside HTTPX
        client = Nokizaru::HTTPClient.for_bulk_requests(
          scan_target,
          timeout_s: effective_timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: num_workers,
          retries: 0
        )

        soft_404_baseline = build_soft_404_baseline(client, normalized_target)
        soft_404_learning = init_soft_404_learning
        soft_404_state = init_soft_404_state
        target_profile = anchor[:profile]

        # Queue-based work distribution
        queue = Queue.new
        urls.each { |url| queue << url }

        workers = Array.new(num_workers) do
          Thread.new do
            error_streak = 0

            # Each worker loops, pulling URLs from queue until empty
            loop do
              # Non-blocking pop - returns nil if queue empty
              url = begin
                queue.pop(true)
              rescue ThreadError
                nil
              end

              break if url.nil? || stop_state[:stop] || $interrupted

              # Make individual request through shared client
              begin
                raw_resp = request_url(client, url, stop_state)
                http_result = HttpResult.new(raw_resp)

                if http_result.success?
                  status = http_result.status
                  error_streak = 0
                  redirect_is_noise = false
                  if INTERESTING_STATUSES.include?(status) && redirect_status?(status)
                    redirect_sample = response_redirect_sample(http_result, request_url: url)
                    redirect_is_noise = redirect_noise?(url, http_result, redirect_sample, soft_404_baseline,
                                                        target_profile)
                  end

                  mutex.synchronize do
                    stats[:success] += 1
                    count += 1

                    if should_stop_now?(count, start_time, stop_state)
                      stop!(stop_state, count, start_time, client)
                      next
                    end

                    if maybe_downgrade_mode!(count, stats, stop_state, timeout_state)
                      client, timeout_state = rebuild_client(
                        client,
                        timeout_state,
                        scan_target,
                        allow_redirects,
                        verify_ssl,
                        thread_cap_for_mode(stop_state[:mode], threads.to_i)
                      )
                      clear_progress_line
                      UI.row(:plus, 'Dir Enum Mode', "#{stop_state[:mode]} (adaptive downgrade)")
                    end

                    if INTERESTING_STATUSES.include?(status)
                      if redirect_is_noise
                        stats[:redirect_filtered] += 1
                        print_progress(count, total) if (count % PROGRESS_EVERY).zero?
                        next
                      end

                      if !redirect_status?(status) && soft_404_active?(soft_404_state, soft_404_baseline)
                        sample = response_sample(http_result, request_url: url)

                        if sample
                          record_soft_404_sample!(soft_404_state)
                          soft_404_baseline = learn_soft_404_baseline(sample, soft_404_baseline, soft_404_learning)
                          disable_soft_404_if_unstable!(soft_404_state, soft_404_baseline, soft_404_learning)

                          if soft_404_match_sample?(sample, soft_404_baseline)
                            stats[:filtered] += 1
                            print_progress(count, total) if (count % PROGRESS_EVERY).zero?
                            next
                          end
                        end
                      end

                      stats[:redirect_outliers] += 1 if redirect_status?(status)

                      responses << [url, status]
                      print_finding(scan_target, url, status, found)
                    end

                    print_progress(count, total) if (count % PROGRESS_EVERY).zero?
                  end
                else
                  error_streak += 1
                  error_kind = classify_error(http_result)

                  mutex.synchronize do
                    stats[:errors] += 1
                    stats[:error_kinds][error_kind] += 1
                    count += 1
                    log_error(url, http_result, stats[:errors])

                    if should_stop_now?(count, start_time, stop_state)
                      stop!(stop_state, count, start_time, client)
                      next
                    end

                    if should_adapt_timeout?(count, stats, timeout_state)
                      client, timeout_state = rebuild_client_with_lower_timeout(
                        client,
                        timeout_state,
                        scan_target,
                        allow_redirects,
                        verify_ssl,
                        thread_cap_for_mode(stop_state[:mode], threads.to_i)
                      )
                      stats[:timeout_downshifts] += 1
                      clear_progress_line
                      UI.row(:plus, 'Adaptive Timeout', "reduced to #{timeout_state[:current]}s (timeout-heavy target)")
                    end

                    print_progress(count, total) if (count % PROGRESS_EVERY).zero?
                  end

                  sleep(error_backoff_s(error_streak, stop_state[:mode]))
                end
              rescue StandardError => e
                error_streak += 1

                mutex.synchronize do
                  stats[:errors] += 1
                  count += 1
                  Log.write("[dirrec] Exception for #{url}: #{e.class}") if stats[:errors] <= 5
                  print_progress(count, total) if (count % PROGRESS_EVERY).zero?
                end

                sleep(error_backoff_s(error_streak, stop_state[:mode]))
              end
            end
          end
        end

        # Wait for all workers to complete
        workers.each(&:join)

        stats[:elapsed] = Time.now - start_time
        print_progress(count, total) # Final progress
        clear_progress_line

        dir_output(responses, found, stats, ctx, original_target: target, effective_target: scan_target,
                                                 reanchored: anchor[:reanchor], reason: anchor[:reason],
                                                 stop_state: stop_state)
        Log.write('[dirrec] Completed')
      end

      # Resolve directory enum anchor target from shared headers profile or local profile fetch
      def resolve_anchor(target, ctx, verify_ssl, timeout_s)
        profile = ctx.run.dig('modules', 'headers', 'target_profile')
        unless profile.is_a?(Hash)
          profile = Nokizaru::TargetIntel.profile(target, verify_ssl: verify_ssl, timeout_s: [timeout_s.to_f, 10.0].min)
        end

        decision = Nokizaru::TargetIntel.reanchor_decision(target, profile)
        decision[:profile] = profile
        decision[:reason] = profile['reason'].to_s
        decision[:reason_code] ||= Nokizaru::TargetIntel.reason_code_for(profile)
        decision
      end

      # Print a discovered directory finding with status and context
      def print_finding(target, url, status, found)
        return if url == "#{target}/"

        found << url
        clear_progress_line
        UI.line(:info, "#{colorize_status(status)} | #{url}")
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
      def print_banner(reanchor_display, mode, threads, timeout_s, effective_timeout, wdlist, allow_redirects,
                       verify_ssl, filext, word_data, total_urls)
        UI.module_header('Starting Directory Enum...')

        rows = [
          ['Re-Anchor', reanchor_display],
          ['Mode', mode],
          ['Threads', threads],
          ['Timeout', timeout_s],
          ['Wordlist', wdlist],
          ['Allow Redirects', allow_redirects],
          ['SSL Verification', verify_ssl],
          ['Wordlist Lines', word_data[:total_lines]],
          ['Usable Entries', word_data[:unique_lines]],
          ['File Extensions', filext],
          ['Total URLs', total_urls]
        ]
        rows.insert(3, ['Effective Timeout', effective_timeout]) if effective_timeout != timeout_s.to_f

        UI.rows(:plus, rows)
        puts
      end

      # Print periodic directory scan progress updates
      def print_progress(current, total)
        print(UI.progress(:info, 'Requests', "#{current}/#{total}"))
        $stdout.flush
      end

      # Clear transient progress line before printing final summary rows
      def clear_progress_line
        print("\r\e[K")
        $stdout.flush
      end

      # Load and normalize wordlist entries used for directory enumeration
      def load_words(wdlist)
        lines = File.readlines(wdlist, chomp: true)
        normalized = lines.map(&:strip).reject(&:empty?)
        unique = normalized.uniq
        {
          words: unique,
          total_lines: lines.length,
          unique_lines: unique.length
        }
      rescue Errno::ENOENT
        UI.line(:error, "Wordlist not found : #{wdlist}")
        Log.write("[dirrec] Wordlist not found: #{wdlist}")
        {
          words: [],
          total_lines: 0,
          unique_lines: 0
        }
      rescue StandardError => e
        UI.line(:error, "Failed to read wordlist : #{e.message}")
        Log.write("[dirrec] Failed to read wordlist: #{e.class} - #{e.message}")
        {
          words: [],
          total_lines: 0,
          unique_lines: 0
        }
      end

      # Probe the target shape quickly so we can select an enumeration mode
      def preflight_probe(target, verify_ssl:, allow_redirects:)
        probe_client = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: PREFLIGHT_TIMEOUT_S,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: 8,
          retries: 0
        )

        urls = preflight_urls(target)
        metrics = {
          total: 0,
          errors: 0,
          timeouts: 0,
          redirects: 0,
          generic_redirects: 0,
          statuses: Hash.new(0)
        }

        q = Queue.new
        urls.each { |u| q << u }

        mtx = Mutex.new
        workers = Array.new(8) do
          Thread.new do
            loop do
              url = begin
                q.pop(true)
              rescue ThreadError
                nil
              end

              break if url.nil? || $interrupted

              begin
                raw = request_url(probe_client, url, { request_method: :head })
                res = HttpResult.new(raw)
                kind = res.success? ? 'ok' : classify_error(res)

                mtx.synchronize do
                  metrics[:total] += 1

                  if res.success?
                    status = res.status.to_i
                    metrics[:statuses][status] += 1
                    if redirect_status?(status)
                      metrics[:redirects] += 1
                      sample = response_redirect_sample(res, request_url: url)
                      if sample && generic_redirect_pattern?(sample[:redirect_pattern].to_s)
                        metrics[:generic_redirects] += 1
                      end
                    end
                  else
                    metrics[:errors] += 1
                    metrics[:timeouts] += 1 if kind == 'timeout'
                  end
                end
              rescue StandardError
                mtx.synchronize do
                  metrics[:total] += 1
                  metrics[:errors] += 1
                end
              end
            end
          end
        end

        workers.each(&:join)

        probe_client.close if probe_client.respond_to?(:close)
        metrics
      rescue StandardError
        {
          total: 0,
          errors: 0,
          timeouts: 0,
          redirects: 0,
          generic_redirects: 0,
          statuses: {}
        }
      end

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

        errors = preflight[:errors].to_i
        timeouts = preflight[:timeouts].to_i
        redirects = preflight[:redirects].to_i
        generic_redirects = preflight[:generic_redirects].to_i

        error_ratio = errors.to_f / total
        timeout_ratio = timeouts.to_f / total
        redirect_ratio = redirects.to_f / total
        generic_ratio = redirects.positive? ? (generic_redirects.to_f / redirects) : 0.0

        return MODE_HOSTILE if timeout_ratio >= 0.05
        return MODE_HOSTILE if error_ratio >= 0.6

        if redirect_ratio >= 0.4 && generic_ratio >= 0.7
          return MODE_HOSTILE if error_ratio >= 0.25

          return MODE_SEEDED
        end

        return MODE_SEEDED if error_ratio >= 0.15

        MODE_FULL
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

      def request_method_for_mode(mode)
        mode == MODE_FULL ? :get : :head
      end

      def thread_cap_for_mode(mode, threads)
        value = threads.to_i
        return [value, 1].max if mode == MODE_FULL

        cap = mode == MODE_HOSTILE ? 12 : 20
        [[value, cap].min, 1].max
      end

      def request_url(client, url, stop_state)
        method = stop_state[:request_method].to_s
        if method == 'head' && client.respond_to?(:head)
          client.head(url)
        else
          client.get(url)
        end
      rescue NoMethodError
        client.get(url)
      end

      # Build the URL list for the chosen enumeration mode
      def build_scan_urls(mode, target, words, filext, ctx, max_seed_paths:)
        case mode
        when MODE_FULL
          build_urls(target, words, filext)
        when MODE_SEEDED
          seed_urls = build_seed_urls(target, ctx, max_seed_paths: max_seed_paths)
          word_urls = build_urls(target, Array(words).first(150), filext)
          (seed_urls + word_urls).uniq.first(max_seed_paths.to_i)
        when MODE_HOSTILE
          build_seed_urls(target, ctx, max_seed_paths: max_seed_paths).first(max_seed_paths.to_i)
        else
          build_urls(target, words, filext)
        end
      end

      # Build seed URLs using crawler artifacts + high-signal endpoints
      def build_seed_urls(target, ctx, max_seed_paths:)
        base = normalize_target_base(target)
        paths = (high_signal_paths + seed_paths_from_crawler(ctx, base)).uniq
        urls = paths.map { |path| join_url(base, path) }.uniq
        urls.first(max_seed_paths.to_i)
      end

      # Extract same-scope paths from crawler module output
      def seed_paths_from_crawler(ctx, base_target)
        crawler = ctx.run.dig('modules', 'crawler')
        return [] unless crawler.is_a?(Hash)

        buckets = %w[internal_links robots_links urls_inside_js urls_inside_sitemap]
        urls = buckets.flat_map { |k| Array(crawler[k]) }
        base_uri = URI.parse(base_target)

        paths = urls.filter_map do |url|
          uri = URI.parse(url.to_s)
          next unless Nokizaru::TargetIntel.same_scope_host?(base_uri.host, uri.host)

          path = uri.path.to_s
          path = '/' if path.empty?
          next if path == '/'

          path
        rescue StandardError
          nil
        end

        paths.uniq
      end

      def high_signal_paths
        %w[
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
        ]
      end

      def join_url(base, path)
        cleaned = path.to_s.strip
        cleaned = "/#{cleaned}" unless cleaned.start_with?('/')
        "#{normalize_target_base(base)}#{cleaned}"
      end

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

        budgets = stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
        max_requests = budgets[:max_requests].to_i
        budget_s = budgets[:budget_s].to_f
        elapsed = Time.now - start_time

        stop_state[:stop] = true
        stop_state[:reason] ||= if max_requests.positive? && count >= max_requests
                                  "request budget hit (#{count}/#{max_requests})"
                                elsif budget_s.positive? && elapsed >= budget_s
                                  "time budget hit (#{elapsed.round(2)}s/#{budget_s}s)"
                                else
                                  'stopped'
                                end

        close_client!(stop_state, client)
      end

      # Build candidate paths from words and optional extensions
      def build_urls(target, words, filext)
        return [] if words.empty?

        base = normalize_target_base(target)
        exts = filext.to_s.strip.empty? ? [] : filext.split(',').map(&:strip)

        urls = if exts.empty?
                 words.map { |w| "#{base}/#{encode_path_word(w)}" }
               else
                 all_exts = [''] + exts
                 words.flat_map do |word|
                   encoded_word = encode_path_word(word)
                   all_exts.map { |ext| ext.empty? ? "#{base}/#{encoded_word}" : "#{base}/#{encoded_word}.#{ext}" }
                 end
               end

        urls.uniq
      end

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
      def dir_output(responses, found, stats, ctx, original_target:, effective_target:, reanchored:, reason:,
                     stop_state:)
        elapsed = stats[:elapsed] || 1
        rps = ((stats[:success] + stats[:errors]) / elapsed).round(1)

        stop_state ||= {}
        mode = stop_state[:mode].to_s
        budgets = stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
        stop_reason = stop_state[:reason].to_s
        preflight = stop_state[:preflight]

        result = {
          'target' => {
            'original' => original_target,
            'effective' => effective_target,
            'reanchored' => reanchored,
            'reason' => reason
          },
          'found' => found.uniq,
          'by_status' => responses.group_by { |(_, s)| s.to_s }.transform_values { |v| v.map(&:first) },
          'stats' => {
            'mode' => mode,
            'stop_reason' => stop_reason.empty? ? nil : stop_reason,
            'budget_seconds' => budgets[:budget_s],
            'max_requests' => budgets[:max_requests],
            'preflight' => preflight,
            'total_requests' => stats[:success] + stats[:errors],
            'successful' => stats[:success],
            'errors' => stats[:errors],
            'error_breakdown' => stats[:error_kinds].to_h,
            'timeout_downshifts' => stats[:timeout_downshifts].to_i,
            'redirect_noise_filtered' => stats[:redirect_filtered].to_i,
            'redirect_outliers' => stats[:redirect_outliers].to_i,
            'elapsed_seconds' => elapsed.round(2),
            'requests_per_second' => rps
          }
        }

        puts
        rows = [
          ['Requests/second', rps],
          ['Directories Found', found.uniq.length]
        ]
        rows << ['Stop Reason', stop_reason] unless stop_reason.to_s.strip.empty?

        UI.rows(:info, rows)
        puts

        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
      end

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

        mode = target_profile.is_a?(Hash) ? target_profile['mode'].to_s : ''
        headers = header_map.is_a?(Hash) ? header_map : {}
        server = headers['server'].to_s.downcase
        powered_by = headers['x-powered-by'].to_s.downcase

        edge = server.include?('cloudflare') || server.include?('akamai') || server.include?('sucuri') ||
               server.include?('imperva') || powered_by.include?('cloudflare')

        edge || !mode.empty?
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
      def rebuild_client_with_lower_timeout(client, timeout_state, target, allow_redirects, verify_ssl, threads)
        next_timeout = [(timeout_state[:current] * 0.6).round(2), timeout_state[:min]].max
        return [client, timeout_state] if next_timeout >= timeout_state[:current]

        client.close if client.respond_to?(:close)

        refreshed = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: next_timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: [threads.to_i, 1].max,
          retries: 0
        )

        [refreshed, timeout_state.merge(current: next_timeout)]
      rescue StandardError
        [client, timeout_state]
      end

      def rebuild_client(client, timeout_state, target, allow_redirects, verify_ssl, threads)
        current_timeout = timeout_state[:current].to_f
        refreshed = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: current_timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: [threads.to_i, 1].max,
          retries: 0
        )

        client.close if client.respond_to?(:close)
        [refreshed, timeout_state]
      rescue StandardError
        [client, timeout_state]
      end

      # Downgrade scan mode during execution if the target becomes hostile under load
      def maybe_downgrade_mode!(count, stats, stop_state, timeout_state)
        return false if stop_state[:stop]
        return false if count < 80

        current_mode = stop_state[:mode].to_s
        return false if current_mode == MODE_HOSTILE

        errors = stats[:errors].to_i
        timeouts = stats[:error_kinds]['timeout'].to_i

        error_ratio = errors.to_f / count
        timeout_ratio = timeouts.to_f / count

        if timeout_ratio >= 0.08 || error_ratio >= 0.75
          stop_state[:mode] = MODE_HOSTILE
          stop_state[:budgets] = MODE_BUDGETS.fetch(MODE_HOSTILE)
          stop_state[:request_method] = request_method_for_mode(MODE_HOSTILE)
          timeout_state[:current] = timeout_for_mode(MODE_HOSTILE, timeout_state[:current])
          return true
        end

        false
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

        return 'timeout' if message.include?('timeout') || message.include?('timed out')
        return 'timeout' if message.include?('waiting on select') || message.include?('waited')
        return 'timeout' if defined?(Timeout::Error) && error.is_a?(Timeout::Error)
        return 'timeout' if defined?(Errno::ETIMEDOUT) && error.is_a?(Errno::ETIMEDOUT)
        return 'timeout' if defined?(IO::TimeoutError) && error.is_a?(IO::TimeoutError)
        return 'timeout' if defined?(HTTPX::TimeoutError) && error.is_a?(HTTPX::TimeoutError)
        return 'tls' if defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
        if message.include?('connection') || message.include?('reset') || message.include?('refused')
          return 'connection'
        end

        'other'
      end

      # Detect wildcard or soft-404 responses so noisy 200 pages are filtered
      def build_soft_404_baseline(client, target)
        samples = []
        SOFT_404_PROBES.times do
          probe_url = "#{normalize_target_base(target)}/#{SecureRandom.hex(10)}"
          raw = client.get(probe_url)
          result = HttpResult.new(raw)
          next unless result.success?

          sample = response_sample(result, request_url: probe_url)
          samples << sample if sample
        rescue StandardError
          nil
        end

        soft_404_baseline_from_samples(samples)
      end

      # Build a compact comparable sample from one HTTP response
      def response_sample(http_result, request_url: nil)
        status = http_result.status.to_i
        return nil unless SOFT_404_SAMPLE_STATUSES.include?(status)

        content_type = normalize_content_type(http_result.headers['content-type'])
        body = http_result.body.to_s
        location = normalized_location_from_request(request_url, http_result.headers['location'])
        redirect_pattern = redirect_pattern(request_url, http_result.headers['location'])
        {
          status: status,
          content_type: content_type,
          body_length: body.bytesize,
          title: extract_title(body),
          fingerprint: body_fingerprint(body),
          location: location,
          redirect_pattern: redirect_pattern
        }
      end

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

        statuses = samples.map { |s| s[:status] }.uniq
        return nil unless statuses.length == 1

        status = statuses.first

        if redirect_status?(status)
          patterns = samples.map { |s| s[:redirect_pattern] }.compact.uniq
          return { status: status, redirect_pattern: patterns.first } if patterns.length == 1

          locations = samples.map { |s| s[:location] }.compact.uniq
          return nil unless locations.length == 1

          return { status: status, location: locations.first }
        end

        content_types = samples.map { |s| s[:content_type] }.uniq
        return nil unless content_types.length == 1

        lengths = samples.map { |s| s[:body_length] }
        return nil if lengths.empty?

        median_length = lengths.sort[lengths.length / 2]
        tolerance = [[(median_length * 0.05).round, SOFT_404_MIN_TOLERANCE].max, SOFT_404_MAX_TOLERANCE].min
        titles = samples.map { |s| s[:title] }.uniq
        baseline_title = titles.length == 1 ? titles.first : nil
        fingerprints = samples.map { |s| s[:fingerprint] }.compact
        baseline_fingerprint = fingerprints.uniq.length == 1 ? fingerprints.first : nil

        {
          status: status,
          content_type: content_types.first,
          body_length: median_length,
          tolerance: tolerance,
          title: baseline_title,
          fingerprint: baseline_fingerprint
        }
      end

      # Check whether a response matches wildcard baseline and should be suppressed
      def soft_404_match?(http_result, baseline)
        sample = response_sample(http_result)
        soft_404_match_sample?(sample, baseline)
      end

      # Check whether a precomputed response sample matches wildcard baseline
      def soft_404_match_sample?(sample, baseline)
        return false unless baseline
        return false unless sample
        return false unless sample[:status] == baseline[:status]

        if redirect_status?(sample[:status])
          return sample[:redirect_pattern] == baseline[:redirect_pattern] if baseline[:redirect_pattern]
          return false unless baseline[:location]

          return sample[:location] == baseline[:location]
        end

        return false unless sample[:content_type] == baseline[:content_type]

        baseline_fingerprint = baseline[:fingerprint]
        sample_fingerprint = sample[:fingerprint]
        return true if baseline_fingerprint && sample_fingerprint && (baseline_fingerprint == sample_fingerprint)

        length_delta = (sample[:body_length] - baseline[:body_length]).abs
        return false if length_delta > baseline[:tolerance]
        return true unless baseline[:title]

        sample[:title] == baseline[:title]
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

      # Learn a fallback baseline from repeated response signatures during enumeration
      def learn_soft_404_baseline(sample, baseline, learning)
        return baseline if baseline || sample.nil?
        return baseline unless SOFT_404_SAMPLE_STATUSES.include?(sample[:status])

        signature_key = if redirect_status?(sample[:status])
                          sample[:redirect_pattern] || sample[:location]
                        else
                          sample[:fingerprint] || sample[:title]
                        end
        return baseline unless signature_key

        learning[:total] += 1
        signature = [sample[:status], sample[:content_type], signature_key, sample[:body_length] / 256]
        learning[:signatures][signature] += 1
        learning[:samples][signature] ||= sample

        top_signature, top_count = learning[:signatures].max_by { |_sig, count| count }
        return baseline unless top_signature && learning[:total] >= 8
        return baseline unless top_count >= 6
        return baseline unless (top_count.to_f / learning[:total]) >= 0.8

        promoted = learning[:samples][top_signature]
        if redirect_status?(promoted[:status])
          return {
            status: promoted[:status],
            location: promoted[:location],
            redirect_pattern: promoted[:redirect_pattern]
          }
        end

        {
          status: promoted[:status],
          content_type: promoted[:content_type],
          body_length: promoted[:body_length],
          tolerance: [[(promoted[:body_length] * 0.05).round, SOFT_404_MIN_TOLERANCE].max, SOFT_404_MAX_TOLERANCE].min,
          title: promoted[:title],
          fingerprint: promoted[:fingerprint]
        }
      end

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

      # Build a generic redirect pattern so path-preserving redirects can be recognized as one behavior class
      def redirect_pattern(request_url, location_header)
        req = URI.parse(request_url.to_s)
        resolved = Nokizaru::TargetIntel.resolve_location(request_url, location_header)
        loc = URI.parse(resolved)
        return nil unless Nokizaru::TargetIntel.same_scope_host?(req.host, loc.host)

        req_path = normalize_pattern_path(req.path)
        loc_path = normalize_pattern_path(loc.path)
        scheme_host = "#{loc.scheme}:#{loc.host.to_s.downcase}"

        if req_path == loc_path
          "same_path:#{scheme_host}"
        elsif "#{req_path}/" == loc_path || (req_path == '/' && loc_path == '/')
          "same_path_slash:#{scheme_host}"
        elsif loc_path == '/'
          "root:#{scheme_host}"
        elsif loc_path.start_with?('/login', '/signin', '/auth')
          "auth_entry:#{scheme_host}"
        else
          "path_specific:#{scheme_host}:#{loc_path}"
        end
      rescue StandardError
        nil
      end

      # Normalize path for redirect pattern comparisons while preserving root
      def normalize_pattern_path(path)
        value = path.to_s
        value = '/' if value.empty?
        return '/' if value == '/'

        value.chomp('/')
      end

      # Determine if current redirect is generic redirect noise and should be filtered
      def redirect_noise?(url, http_result, sample, baseline, target_profile)
        return false unless redirect_status?(http_result.status)
        return true unless sample

        if Nokizaru::TargetIntel.path_preserving_https_redirect?(url, http_result.headers['location'], target_profile)
          return true
        end

        return true if soft_404_match_sample?(sample, baseline)
        return false if redirect_outlier?(sample)

        pattern = sample[:redirect_pattern].to_s
        return true if generic_redirect_pattern?(pattern)

        true
      end

      # Generic redirect patterns are likely anti-enumeration normalizers unless they diverge from baseline
      def generic_redirect_pattern?(pattern)
        pattern.start_with?('same_path:', 'same_path_slash:', 'root:', 'auth_entry:')
      end

      # Keep only meaningful redirect outliers and suppress generic redirect noise from live findings
      def redirect_outlier?(sample)
        pattern = sample[:redirect_pattern].to_s
        return false if pattern.empty?

        return false if generic_redirect_pattern?(pattern)
        return false unless pattern.start_with?('path_specific:')

        location_path = sample[:location].to_s.split('/', 2)[1].to_s
        return false if location_path.empty?

        redirect_target_keyword?(location_path)
      end

      # Prefer redirect findings that route toward meaningful app entry points
      def redirect_target_keyword?(path)
        normalized = "/#{path}".downcase
        %w[/admin /login /signin /auth /account /dashboard /api /graphql /wp-admin].any? do |prefix|
          normalized.start_with?(prefix)
        end
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
