# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Stats aggregation and preview output helpers
      module Stats
        require 'uri'

        BUCKETS = %w[
          robots_links sitemap_links css_links js_links internal_links external_links
          images urls_inside_sitemap urls_inside_js
        ].freeze
        LOW_SIGNAL_EXTENSIONS = %w[
          .png .jpg .jpeg .gif .webp .svg .ico .bmp .tif .tiff .avif
          .css .less .scss .sass .js .mjs .map .ts
          .woff .woff2 .ttf .otf .eot
          .pdf .zip .gz .bz2 .xz .7z .rar .tar .tgz
          .mp3 .wav .ogg .m4a .mp4 .webm .mov .avi .mkv
        ].freeze
        HIGH_SIGNAL_TOKENS = %w[
          admin login signin auth account dashboard api graphql oauth token
          config backup env passwd private internal wp-admin wp-login
        ].freeze

        private

        def calculate_stats(result)
          counts = BUCKETS.to_h { |name| [name, Array(result[name]).length] }
          all_urls = BUCKETS.flat_map { |name| Array(result[name]) }.uniq
          stats_hash(counts, all_urls)
        end

        def stats_hash(counts, all_urls)
          high_signal = high_signal_urls_from_list(all_urls)
          {
            'robots_count' => counts['robots_links'], 'sitemap_count' => counts['sitemap_links'],
            'css_count' => counts['css_links'], 'js_count' => counts['js_links'],
            'internal_count' => counts['internal_links'], 'external_count' => counts['external_links'],
            'images_count' => counts['images'], 'sitemap_url_count' => counts['urls_inside_sitemap'],
            'js_url_count' => counts['urls_inside_js'],
            'high_signal_count' => high_signal.length,
            'total_unique' => all_urls.length,
            'total_urls' => all_urls,
            'high_signal_urls' => high_signal
          }
        end

        def high_signal_urls(result)
          sources = %w[internal_links robots_links urls_inside_js urls_inside_sitemap]
          urls = sources.flat_map { |name| Array(result[name]) }.uniq
          high_signal_urls_from_list(urls)
        end

        def high_signal_urls_from_list(urls)
          Array(urls)
            .compact
            .uniq
            .map { |url| [url, score_url(url)] }
            .select { |(_, score)| score.positive? }
            .sort_by { |(url, score)| [-score, url.length] }
            .first(250)
            .map(&:first)
        end

        def score_url(url)
          uri = URI.parse(url)
          path = uri.path.to_s.downcase
          return 0 if path.empty?
          return 0 if LOW_SIGNAL_EXTENSIONS.any? { |ext| path.end_with?(ext) }

          score = 0
          score += 4 if HIGH_SIGNAL_TOKENS.any? { |token| path.include?(token) }
          score += 2 if path.count('/') >= 2
          score += 1 unless uri.query.to_s.empty?
          score
        rescue StandardError
          0
        end

        def print_links_preview(label, links)
          values = Array(links).compact.uniq
          return if values.empty?

          UI.line(:info, "#{label} Preview")
          values.first(Crawler::PREVIEW_LIMIT).each { |link| puts("    #{UI::C}#{link}#{UI::W}") }
          print_remaining_count(values.length)
        end

        def print_remaining_count(total)
          remaining = total - Crawler::PREVIEW_LIMIT
          return unless remaining.positive?

          puts("    #{UI::C}... #{remaining} more#{UI::W}")
        end
      end
    end
  end
end
