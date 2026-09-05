# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Preparation
        include PathHelpers

        private

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
          url_plan = build_scan_plan(
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
            url_plan: url_plan,
            total_urls: url_plan[:estimated_total],
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
            allow_redirects: options[:allow_redirects]
          )
        rescue StandardError
          nil
        ensure
          client.close if client.respond_to?(:close)
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

        def build_scan_plan(config)
          seed_urls = build_seed_urls(config[:target], config[:ctx])
          words = prioritized_words(config[:words], seed_urls)
          extensions = file_extensions(config[:filext])
          {
            seed_urls: seed_urls,
            words: words,
            extensions: extensions,
            estimated_total: estimated_url_total(seed_urls, words, extensions)
          }
        end

        def estimated_url_total(seed_urls, words, extensions)
          seed_urls.length + words.length + (words.length * extensions.length)
        end

        # Build seed URLs using crawler artifacts + high-signal endpoints
        def build_seed_urls(target, ctx)
          base = normalize_target_base(target)
          paths = (HIGH_SIGNAL_PATHS + seed_paths_from_crawler(ctx, base)).uniq
          paths.map { |path| join_url(base, path) }.uniq
        end

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
          %w[high_signal_urls internal_links robots_links urls_inside_js urls_inside_sitemap].flat_map do |key|
            Array(crawler[key])
          end
        end

        def crawler_seed_path(url, base_uri)
          uri = URI.parse(url.to_s)
          return nil unless Nokizaru::TargetIntel.same_scope_host?(base_uri.host, uri.host)

          path = uri.path.to_s
          path = '/' if path.empty?
          path = relative_seed_path(path, base_uri.path.to_s)
          return nil if path == '/'

          path
        end

        def relative_seed_path(path, base_path)
          cleaned_base = base_path.to_s.chomp('/')
          return path if cleaned_base.empty? || cleaned_base == '/'
          return '/' if path == cleaned_base
          return path unless path.start_with?("#{cleaned_base}/")

          path.delete_prefix(cleaned_base)
        end

        def prioritized_words(words, seed_urls)
          seeded_paths = seed_urls.map { |url| URI.parse(url).path.delete_prefix('/') }.compact.to_set
          words.uniq.sort_by do |word|
            encoded = encode_path_word(word)
            [seeded_paths.include?(encoded) ? 1 : 0, extension_worthy_word?(word) ? 0 : 1, encoded.length]
          end
        rescue StandardError
          words.uniq
        end

        def extension_worthy_word?(word)
          value = word.to_s.downcase
          return false if value.empty? || value.include?('.')

          HIGH_SIGNAL_PATHS.any? { |seed| seed.delete_prefix('/').start_with?(value) } ||
            %w[index admin login api config backup db upload dashboard].include?(value)
        end

        def file_extensions(filext)
          value = filext.to_s.strip
          return [] if value.empty?

          value.split(',').map(&:strip)
        end
      end
    end
  end
end
