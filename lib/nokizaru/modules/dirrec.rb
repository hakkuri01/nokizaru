# frozen_string_literal: true

require 'set'
require 'securerandom'
require 'zlib'
require 'uri'

require_relative '../http_client'
require_relative '../http_result'
require_relative '../log'

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
      REDIRECT_STATUSES = Set[301, 302, 303, 307, 308].freeze
      SOFT_404_SAMPLE_STATUSES = Set[200, 403, 301, 302, 303, 307, 308].freeze

      INTERESTING_STATUSES = Set[200, 301, 302, 303, 307, 308, 403].freeze

      # Run this module and store normalized results in the run context
      def call(target, threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, ctx)
        word_data = load_words(wdlist)
        words = word_data[:words]
        urls = build_urls(target, words, filext)
        total = urls.length
        effective_timeout = effective_timeout_s(timeout_s)

        print_banner(threads, timeout_s, effective_timeout, wdlist, allow_redirects, verify_ssl, filext, word_data,
                     total)

        # Thread-safe result storage
        mutex = Mutex.new
        responses = []
        found = []
        stats = { success: 0, errors: 0, filtered: 0 }
        count = 0

        # Build one shared client - all workers use this same client
        # Connection pooling happens automatically inside HTTPX
        client = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: effective_timeout,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: [threads.to_i, 1].max,
          retries: 0
        )

        soft_404_baseline = build_soft_404_baseline(client, target)
        soft_404_learning = init_soft_404_learning
        soft_404_state = init_soft_404_state

        # Queue-based work distribution
        queue = Queue.new
        urls.each { |url| queue << url }

        # Create worker threads
        num_workers = [threads.to_i, 1].max
        start_time = Time.now

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

              break if url.nil? || $interrupted

              # Make individual request through shared client
              begin
                raw_resp = client.get(url)
                http_result = HttpResult.new(raw_resp)

                if http_result.success?
                  status = http_result.status
                  error_streak = 0

                  mutex.synchronize do
                    stats[:success] += 1
                    count += 1

                    if INTERESTING_STATUSES.include?(status)
                      if soft_404_active?(soft_404_state, soft_404_baseline)
                        sample = response_sample(http_result)

                        if sample
                          record_soft_404_sample!(soft_404_state)
                          soft_404_baseline = learn_soft_404_baseline(sample, soft_404_baseline, soft_404_learning)
                          disable_soft_404_if_unstable!(soft_404_state, soft_404_baseline, soft_404_learning)

                          if soft_404_match_sample?(sample, soft_404_baseline)
                            stats[:filtered] += 1
                            print_progress(count, total) if (count % 50).zero?
                            next
                          end
                        end
                      end

                      responses << [url, status]
                      print_finding(target, url, status, found)
                    end

                    print_progress(count, total) if (count % 50).zero?
                  end
                else
                  error_streak += 1

                  mutex.synchronize do
                    stats[:errors] += 1
                    count += 1
                    log_error(url, http_result, stats[:errors])
                    print_progress(count, total) if (count % 50).zero?
                  end

                  sleep(error_backoff_s(error_streak))
                end
              rescue StandardError => e
                error_streak += 1

                mutex.synchronize do
                  stats[:errors] += 1
                  count += 1
                  Log.write("[dirrec] Exception for #{url}: #{e.class}") if stats[:errors] <= 5
                  print_progress(count, total) if (count % 50).zero?
                end

                sleep(error_backoff_s(error_streak))
              end
            end
          end
        end

        # Wait for all workers to complete
        workers.each(&:join)

        stats[:elapsed] = Time.now - start_time
        print_progress(count, total) # Final progress
        clear_progress_line

        dir_output(responses, found, stats, ctx)
        Log.write('[dirrec] Completed')
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
        color = if code >= 200 && code < 300
                  UI::G
                elsif code >= 300 && code < 500
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
      def print_banner(threads, timeout_s, effective_timeout, wdlist, allow_redirects, verify_ssl, filext, word_data,
                       total_urls)
        UI.module_header('Starting Directory Enum...')

        rows = [
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
        rows.insert(2, ['Effective Timeout', effective_timeout]) if effective_timeout != timeout_s.to_f

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

      # Build candidate paths from words and optional extensions
      def build_urls(target, words, filext)
        return [] if words.empty?

        exts = filext.to_s.strip.empty? ? [] : filext.split(',').map(&:strip)

        urls = if exts.empty?
                 words.map { |w| "#{target}/#{encode_path_word(w)}" }
               else
                 all_exts = [''] + exts
                 words.flat_map do |word|
                   encoded_word = encode_path_word(word)
                   all_exts.map { |ext| ext.empty? ? "#{target}/#{encoded_word}" : "#{target}/#{encoded_word}.#{ext}" }
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
      def dir_output(responses, found, stats, ctx)
        elapsed = stats[:elapsed] || 1
        rps = ((stats[:success] + stats[:errors]) / elapsed).round(1)

        result = {
          'found' => found.uniq,
          'by_status' => responses.group_by { |(_, s)| s.to_s }.transform_values { |v| v.map(&:first) },
          'stats' => {
            'total_requests' => stats[:success] + stats[:errors],
            'successful' => stats[:success],
            'errors' => stats[:errors],
            'elapsed_seconds' => elapsed.round(2),
            'requests_per_second' => rps
          }
        }

        puts
        UI.rows(:info, [
                  ['Directories Found', found.uniq.length],
                  ['Requests/second', rps],
                  ['Soft 404 Filtered', stats[:filtered]],
                  ['Errors', stats[:errors]]
                ])
        puts

        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
      end

      # Clamp directory enumeration timeout to reduce long-tail stalls on strict targets
      def effective_timeout_s(timeout_s)
        timeout = timeout_s.to_f
        return DEFAULT_EFFECTIVE_TIMEOUT_S unless timeout.positive?

        [timeout, MAX_EFFECTIVE_TIMEOUT_S].min
      end

      # Detect wildcard or soft-404 responses so noisy 200 pages are filtered
      def build_soft_404_baseline(client, target)
        samples = []
        SOFT_404_PROBES.times do
          probe_url = "#{target}/#{SecureRandom.hex(10)}"
          raw = client.get(probe_url)
          result = HttpResult.new(raw)
          next unless result.success?

          sample = response_sample(result)
          samples << sample if sample
        rescue StandardError
          nil
        end

        soft_404_baseline_from_samples(samples)
      end

      # Build a compact comparable sample from one HTTP response
      def response_sample(http_result)
        status = http_result.status.to_i
        return nil unless SOFT_404_SAMPLE_STATUSES.include?(status)

        content_type = normalize_content_type(http_result.headers['content-type'])
        body = http_result.body.to_s
        location = normalize_location(http_result.headers['location'])
        {
          status: status,
          content_type: content_type,
          body_length: body.bytesize,
          title: extract_title(body),
          fingerprint: body_fingerprint(body),
          location: location
        }
      end

      # Compute a soft-404 baseline from probe samples when they are consistent
      def soft_404_baseline_from_samples(samples)
        return nil if samples.length < SOFT_404_MIN_PROBES

        statuses = samples.map { |s| s[:status] }.uniq
        return nil unless statuses.length == 1

        status = statuses.first

        if redirect_status?(status)
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
                          sample[:location]
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
        return { status: promoted[:status], location: promoted[:location] } if redirect_status?(promoted[:status])

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

      # Check whether status code represents an HTTP redirect response
      def redirect_status?(status)
        REDIRECT_STATUSES.include?(status.to_i)
      end

      # Apply tiny per-worker backoff on sustained errors to improve useful throughput under strict targets
      def error_backoff_s(error_streak)
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
