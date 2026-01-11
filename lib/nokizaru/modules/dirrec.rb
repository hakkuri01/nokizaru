# frozen_string_literal: true

require_relative '../http_client'
require_relative '../http_result'
require_relative '../log'

module Nokizaru
  module Modules
    module DirectoryEnum
      module_function

      R = "\e[31m"
      G = "\e[32m"
      C = "\e[36m"
      W = "\e[0m"
      Y = "\e[33m"

      DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0'

      INTERESTING_STATUSES = Set[200, 301, 302, 303, 307, 308, 403].freeze

      def call(target, threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, ctx)
        print_banner(threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext)

        words = File.readlines(wdlist, chomp: true).reject(&:empty?)
        urls = build_urls(target, words, filext)
        total = urls.length

        puts("#{G}[+] #{C}Total URLs       : #{W}#{total}\n\n")

        # Thread-safe result storage
        mutex = Mutex.new
        responses = []
        found = []
        stats = { success: 0, errors: 0 }
        count = 0

        # Build one shared client - all workers use this same client
        # Connection pooling happens automatically inside HTTPX
        client = Nokizaru::HTTPClient.for_host(
          target,
          timeout_s: timeout_s.to_f,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: !!allow_redirects,
          verify_ssl: !!verify_ssl
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

                    # Progress update every 50 requests
                    print_progress(count, total) if (count % 50).zero?
                  end
                else
                  mutex.synchronize do
                    stats[:errors] += 1
                    count += 1
                    log_error(url, http_result, stats[:errors])
                  end
                end
              rescue StandardError => e
                mutex.synchronize do
                  stats[:errors] += 1
                  count += 1
                  Log.write("[dirrec] Exception for #{url}: #{e.class}") if stats[:errors] <= 5
                end
              end
            end
          end
        end

        # Wait for all workers to complete
        workers.each(&:join)

        stats[:elapsed] = Time.now - start_time
        print_progress(count, total) # Final progress

        dir_output(responses, found, stats, ctx)
        Log.write('[dirrec] Completed')
      end

      def print_finding(target, url, status, found)
        return if url == "#{target}/"

        found << url

        case status
        when 200
          puts("\r\e[K#{G}#{status} #{C}|#{W} #{url}")
        when 301, 302, 303, 307, 308
          puts("\r\e[K#{Y}#{status} #{C}|#{W} #{url}")
        when 403
          puts("\r\e[K#{R}#{status} #{C}|#{W} #{url}")
        end
      end

      def log_error(_url, http_result, error_count)
        return if error_count > 5

        if error_count == 5
          Log.write('[dirrec] Suppressing further error logs')
        else
          Log.write("[dirrec] Error: #{http_result.error_message}")
        end
      end

      def print_banner(threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext)
        puts("\n#{Y}[!] Starting Directory Enum...#{W}\n\n")
        puts("#{G}[+] #{C}Threads          : #{W}#{threads}")
        puts("#{G}[+] #{C}Timeout          : #{W}#{timeout_s}")
        puts("#{G}[+] #{C}Wordlist         : #{W}#{wdlist}")
        puts("#{G}[+] #{C}Allow Redirects  : #{W}#{allow_redirects}")
        puts("#{G}[+] #{C}SSL Verification : #{W}#{verify_ssl}")

        num_words = File.foreach(wdlist).count
        puts("#{G}[+] #{C}Wordlist Size    : #{W}#{num_words}")
        puts("#{G}[+] #{C}File Extensions  : #{W}#{filext}")
      end

      def print_progress(current, total)
        print("#{Y}[!] #{C}Requests : #{W}#{current}/#{total}\r")
        $stdout.flush
      end

      def build_urls(target, words, filext)
        exts = filext.to_s.strip.empty? ? [] : filext.split(',').map(&:strip)

        if exts.empty?
          words.map { |w| "#{target}/#{w}" }
        else
          # Bare path + each extension
          all_exts = [''] + exts
          words.flat_map do |word|
            all_exts.map { |ext| ext.empty? ? "#{target}/#{word}" : "#{target}/#{word}.#{ext}" }
          end
        end
      end

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

        puts("\n\n#{G}[+] #{C}Directories Found   : #{W}#{found.uniq.length}")
        puts("#{G}[+] #{C}Requests/second     : #{W}#{rps}")
        puts("#{Y}[!] #{C}Errors              : #{W}#{stats[:errors]}\n\n")

        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
      end
    end
  end
end
