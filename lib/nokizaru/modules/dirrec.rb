# frozen_string_literal: true

require 'set'
require 'uri'

require_relative '../http_client'
require_relative '../http_result'
require_relative '../log'

module Nokizaru
  module Modules
    module DirectoryEnum
      module_function

      DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0'

      INTERESTING_STATUSES = Set[200, 301, 302, 303, 307, 308, 403].freeze

      # Run this module and store normalized results in the run context
      def call(target, threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, ctx)
        word_data = load_words(wdlist)
        words = word_data[:words]
        urls = build_urls(target, words, filext)
        total = urls.length

        print_banner(threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, word_data, total)

        # Thread-safe result storage
        mutex = Mutex.new
        responses = []
        found = []
        stats = { success: 0, errors: 0 }
        count = 0

        # Build one shared client - all workers use this same client
        # Connection pooling happens automatically inside HTTPX
        client = Nokizaru::HTTPClient.for_bulk_requests(
          target,
          timeout_s: timeout_s.to_f,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          max_concurrent: [threads.to_i, 1].max
        )

        # Queue-based work distribution
        queue = Queue.new
        urls.each { |url| queue << url }

        # Create worker threads
        num_workers = [threads.to_i, 1].max
        start_time = Time.now

        workers = Array.new(num_workers) do
          Thread.new do
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

                  mutex.synchronize do
                    stats[:success] += 1
                    count += 1

                    if INTERESTING_STATUSES.include?(status)
                      responses << [url, status]
                      print_finding(target, url, status, found)
                    end

                    print_progress(count, total) if (count % 50).zero?
                  end
                else
                  mutex.synchronize do
                    stats[:errors] += 1
                    count += 1
                    log_error(url, http_result, stats[:errors])
                    print_progress(count, total) if (count % 50).zero?
                  end
                end
              rescue StandardError => e
                mutex.synchronize do
                  stats[:errors] += 1
                  count += 1
                  Log.write("[dirrec] Exception for #{url}: #{e.class}") if stats[:errors] <= 5
                  print_progress(count, total) if (count % 50).zero?
                end
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
        UI.line(:info, "#{status} | #{url}")
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
      def print_banner(threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, word_data, total_urls)
        UI.module_header('Starting Directory Enum...')

        UI.rows(:plus, [
                  ['Threads', threads],
                  ['Timeout', timeout_s],
                  ['Wordlist', wdlist],
                  ['Allow Redirects', allow_redirects],
                  ['SSL Verification', verify_ssl],
                  ['Wordlist Lines', word_data[:total_lines]],
                  ['Usable Entries', word_data[:unique_lines]],
                  ['File Extensions', filext],
                  ['Total URLs', total_urls]
                ])
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
                  ['Errors', stats[:errors]]
                ])
        puts

        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
      end
    end
  end
end
