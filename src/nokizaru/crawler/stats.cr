require "uri"
require "set"
require "./result"

module Nokizaru
  module Crawler
    # Computes the crawl stats and the high-signal URL ranking. All work is over
    # the already-capped link buckets, so it runs once per scan: an O(n) dedup
    # across the buckets and an O(n log n) sort to rank the high-signal URLs
    # (n bounded by the sum of the caps).
    module Statistics
      extend self

      # The nine link buckets that make up total_urls, in Ruby BUCKETS order.
      # Extensions that mark a URL as low-signal (static assets, archives, media).
      LOW_SIGNAL_EXTENSIONS = %w[
        .png .jpg .jpeg .gif .webp .svg .ico .bmp .tif .tiff .avif
        .css .less .scss .sass .js .mjs .map .ts
        .woff .woff2 .ttf .otf .eot
        .pdf .zip .gz .bz2 .xz .7z .rar .tar .tgz
        .mp3 .wav .ogg .m4a .mp4 .webm .mov .avi .mkv
      ]

      # Path tokens that mark a URL as high-signal (admin, auth, API, secrets).
      HIGH_SIGNAL_TOKENS = %w[
        admin login signin auth account dashboard api graphql oauth token
        config backup env passwd private internal wp-admin wp-login
      ]

      # The top-level high_signal_urls draw from these four buckets, not all nine.
      def high_signal(result : Result) : Array(String)
        urls = [] of String
        urls.concat(result.internal_links)
        urls.concat(result.robots_links)
        urls.concat(result.urls_inside_js)
        urls.concat(result.urls_inside_sitemap)
        high_signal_from_list(urls)
      end

      def calculate(result : Result, crawl_mode : String, crawl_notes : Array(String)) : Stats
        all_urls = unique_urls(result)
        ranked = high_signal_from_list(all_urls)
        Stats.new(
          robots_count: result.robots_links.size,
          sitemap_count: result.sitemap_links.size,
          css_count: result.css_links.size,
          js_count: result.js_links.size,
          internal_count: result.internal_links.size,
          external_count: result.external_links.size,
          images_count: result.images.size,
          sitemap_url_count: result.urls_inside_sitemap.size,
          js_url_count: result.urls_inside_js.size,
          high_signal_count: ranked.size,
          total_unique: all_urls.size,
          total_urls: all_urls,
          high_signal_urls: ranked,
          crawl_mode: crawl_mode,
          crawl_notes: crawl_notes,
        )
      end

      private def unique_urls(result : Result) : Array(String)
        all = [] of String
        all.concat(result.robots_links)
        all.concat(result.sitemap_links)
        all.concat(result.css_links)
        all.concat(result.js_links)
        all.concat(result.internal_links)
        all.concat(result.external_links)
        all.concat(result.images)
        all.concat(result.urls_inside_sitemap)
        all.concat(result.urls_inside_js)
        all.uniq
      end

      private def high_signal_from_list(urls : Array(String)) : Array(String)
        seen = Set(String).new
        scored = [] of {String, Int32}
        urls.each do |url|
          next unless seen.add?(url)

          score = score_url(url)
          scored << {url, score} if score > 0
        end
        scored.sort_by! { |(url, score)| {-score, url.size} }
        scored.first(250).map { |(url, _)| url }
      end

      private def score_url(url : String) : Int32
        path = URI.parse(url).path.downcase
        return 0 if path.empty?
        return 0 if LOW_SIGNAL_EXTENSIONS.any? { |ext| path.ends_with?(ext) }

        score = 0
        score += 4 if HIGH_SIGNAL_TOKENS.any? { |token| path.includes?(token) }
        score += 2 if path.count('/') >= 2
        query = URI.parse(url).query
        score += 1 if query && !query.empty?
        score
      rescue
        0
      end
    end
  end
end
