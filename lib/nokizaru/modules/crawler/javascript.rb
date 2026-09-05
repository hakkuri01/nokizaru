# frozen_string_literal: true

require 'uri'

module Nokizaru
  module Modules
    module Crawler
      module JavaScript
        private

        def js_crawl(result, js_links, page_url, request_headers)
          apply_adaptive_budget!(result)
          return [] if crawl_budget_exhausted?(result)

          targets = scoped_js_targets(result, js_links, page_url)
          return [] if targets.empty?

          urls = []
          mutex = Mutex.new
          each_concurrently(targets) do |js|
            next if crawl_budget_exhausted?(result)

            extracted = extract_urls_from_javascript(js, page_url, request_headers)
            mutex.synchronize do
              urls.concat(extracted)
              urls.uniq!
              max_js_urls_total = adaptive_limit(result, :max_js_urls_total)
              urls.slice!(max_js_urls_total..) if urls.length > max_js_urls_total
            end
          end
          urls = urls.first(adaptive_limit(result, :max_js_urls_total))
          step_row(:info, 'Crawling Javascripts', urls.length)
          urls
        end

        def extract_urls_from_javascript(js_url, page_url, request_headers)
          response = http_get(js_url, request_headers: request_headers)
          return [] unless http_success?(response)

          found = Nokizaru::HTTPClient.response_body(response).scan(%r{https?://[\w\-.~:/?#\[\]@!$&'()*+,;=%]+})
          normalize_extracted_urls(found, page_url)
        rescue StandardError => e
          Log.write("[crawler.js_crawl] Exception = #{e}")
          []
        end

        def normalize_extracted_urls(found, page_url)
          base = URI.parse(page_url)
          values = Array(found)
                   .map { |url| sanitize_extracted_url(url) }
                   .reject(&:empty?)
                   .select { |url| same_scope_url?(url, base.host) }
                   .uniq
          values.first(Crawler::MAX_JS_URLS_PER_FILE)
        rescue StandardError
          []
        end

        def sanitize_extracted_url(url)
          cleaned = url.to_s.sub(/["'`,;\])]+\z/, '')
          return '' if cleaned.empty?

          uri = URI.parse(cleaned)
          return '' unless uri.is_a?(URI::HTTP) && uri.host

          cleaned
        rescue StandardError
          ''
        end

        def same_scope_url?(url, target_host)
          uri = URI.parse(url)
          return false unless uri.is_a?(URI::HTTP) && uri.host

          Nokizaru::TargetIntel.same_scope_host?(uri.host, target_host)
        rescue StandardError
          false
        end

        def scoped_js_targets(result, js_links, page_url)
          base = URI.parse(page_url)
          links = Array(js_links).compact.uniq.select { |url| same_scope_url?(url, base.host) }
          links.first(adaptive_limit(result, :max_js_targets))
        end
      end
    end
  end
end
