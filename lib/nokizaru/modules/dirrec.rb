# frozen_string_literal: true

require_relative '../http_client'
require 'concurrent'
require_relative '../log'

module Nokizaru
  module Modules
    module DirectoryEnum
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0'

      def call(target, threads, timeout_s, wdlist, allow_redirects, verify_ssl, filext, ctx)
        puts("\n#{Y}[!] Starting Directory Enum...#{W}\n\n")
        puts("#{G}[+] #{C}Threads          : #{W}#{threads}")
        puts("#{G}[+] #{C}Timeout          : #{W}#{timeout_s}")
        puts("#{G}[+] #{C}Wordlist         : #{W}#{wdlist}")
        puts("#{G}[+] #{C}Allow Redirects  : #{W}#{allow_redirects}")
        puts("#{G}[+] #{C}SSL Verification : #{W}#{verify_ssl}")

        words = File.readlines(wdlist, chomp: true)
        num_words = words.length
        puts("#{G}[+] #{C}Wordlist Size    : #{W}#{num_words}")
        puts("#{G}[+] #{C}File Extensions  : #{W}#{filext}\n")

        urls = build_urls(target, words, filext)
        total = urls.length

        # Keep allocations low; only need to record interesting statuses.
        responses = Concurrent::Array.new
        found = Concurrent::Array.new
        exc_count = Concurrent::AtomicFixnum.new(0)
        count = Concurrent::AtomicFixnum.new(0)

        # Build client once; avoid per-request options (faster and more compatible across HTTPX versions).
        client = Nokizaru::HTTPClient.build(
          timeout_s: timeout_s.to_f,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: !!allow_redirects,
          persistent: true,
          verify_ssl: !!verify_ssl
        )

        # Ruby threadpool scheduling overhead is significant at 4k+ tiny requests.
        # Instead, spin up N long-lived workers that each consume many URLs.
        q = Queue.new
        urls.each { |u| q << u }

        worker_n = [Integer(threads), 1].max
        # Updating the progress line too frequently can dominate runtime on fast hosts.
        update_every = 200

        workers = Array.new(worker_n) do
          Thread.new do
            loop do
              url = begin
                q.pop(true)
              rescue StandardError
                nil
              end
              break unless url

              begin
                resp = client.get(url)
                status = resp.respond_to?(:status) ? resp.status : nil
                if status
                  # Keep only interesting statuses.
                  if status == 200 || status == 403 || [301, 302, 303, 307, 308].include?(status)
                    responses << [url, status]
                  end
                  filter_out(target, url, status, found)
                else
                  exc_count.increment
                  Log.write("[dirrec] HTTP error response for #{url}")
                end
              rescue StandardError => e
                exc_count.increment
                Log.write("[dirrec] Exception : #{e}")
              ensure
                current = count.increment
                # Avoid excessive terminal churn; this alone can dwarf network time.
                if (current % update_every).zero? || current == total
                  print("#{Y}[!] #{C}Requests : #{W}#{current}/#{total}\r")
                end
              end
            end
          end
        end

        workers.each(&:join)

        dir_output(responses, found, exc_count.value, ctx)
        Log.write('[dirrec] Completed')
      end

      def build_urls(target, words, filext)
        exts = []
        exts = filext.split(',').map(&:strip) if filext && !filext.strip.empty?

        urls = []
        if exts.empty?
          words.each do |word|
            next if word.nil? || word.empty?

            urls << "#{target}/#{word}"
          end
        else
          # Also probe the bare path with no extension
          exts_with_empty = [''] + exts
          words.each do |word|
            next if word.nil? || word.empty?

            exts_with_empty.each do |ext|
              urls << if ext.empty?
                        "#{target}/#{word}"
                      else
                        "#{target}/#{word}.#{ext}"
                      end
            end
          end
        end
        urls
      end

      def filter_out(target, url, status, found)
        if status == 200
          unless url == "#{target}/"
            found << url
            puts("#{G}#{status} #{C}|#{W} #{url}")
          end
        elsif [301, 302, 303, 307, 308].include?(status)
          found << url
          puts("#{Y}#{status} #{C}|#{W} #{url}")
        elsif status == 403
          found << url
          puts("#{R}#{status} #{C}|#{W} #{url}")
        end
      end

      def dir_output(responses, found, exc_count, ctx)
        result = { 'found' => [], 'by_status' => {}, 'exceptions' => exc_count }

        responses.each do |(url, status)|
          next unless status

          if status == 200
            (result['by_status']['200'] ||= []) << url
          elsif [301, 302, 303, 307, 308].include?(status)
            (result['by_status'][status.to_s] ||= []) << url
          elsif status == 403
            (result['by_status']['403'] ||= []) << url
          end
        end

        result['found'] = found.uniq

        puts("\n\n#{G}[+] #{C}Directories Found   : #{W}#{found.uniq.length}\n\n")
        puts("#{Y}[!] #{C}Exceptions          : #{W}#{exc_count}")

        ctx.run['modules']['directory_enum'] = result
        ctx.add_artifact('paths', result['found'])
      end
    end
  end
end
