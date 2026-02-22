# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # JavaScript source crawling and URL extraction helpers
      module JavaScript
        private

        def js_crawl(js_links)
          targets = Array(js_links).compact.uniq
          return [] if targets.empty?

          urls = []
          each_in_threads(targets) { |js| urls.concat(extract_urls_from_javascript(js)) }
          urls = urls.uniq
          step_row(:info, 'Crawling Javascripts', urls.length)
          urls
        end

        def extract_urls_from_javascript(js_url)
          response = http_get(js_url)
          return [] unless response.is_a?(Net::HTTPSuccess)

          found = response.body.scan(%r{https?://[\w\-.~:/?#\[\]@!$&'()*+,;=%]+})
          found.map { |url| sanitize_extracted_url(url) }.reject(&:empty?)
        rescue StandardError => e
          Log.write("[crawler.js_crawl] Exception = #{e}")
          []
        end

        def sanitize_extracted_url(url)
          url.to_s.sub(/["'`,;\])]+\z/, '')
        end
      end
    end
  end
end
