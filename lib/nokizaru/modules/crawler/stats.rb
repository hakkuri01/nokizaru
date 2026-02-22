# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Stats aggregation and preview output helpers
      module Stats
        BUCKETS = %w[
          robots_links sitemap_links css_links js_links internal_links external_links
          images urls_inside_sitemap urls_inside_js
        ].freeze

        private

        def calculate_stats(result)
          counts = BUCKETS.to_h { |name| [name, Array(result[name]).length] }
          all_urls = BUCKETS.flat_map { |name| Array(result[name]) }.uniq
          stats_hash(counts, all_urls)
        end

        def stats_hash(counts, all_urls)
          {
            'robots_count' => counts['robots_links'], 'sitemap_count' => counts['sitemap_links'],
            'css_count' => counts['css_links'], 'js_count' => counts['js_links'],
            'internal_count' => counts['internal_links'], 'external_count' => counts['external_links'],
            'images_count' => counts['images'], 'sitemap_url_count' => counts['urls_inside_sitemap'],
            'js_url_count' => counts['urls_inside_js'],
            'total_unique' => all_urls.length,
            'total_urls' => all_urls
          }
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
