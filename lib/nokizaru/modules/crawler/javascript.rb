# frozen_string_literal: true

require 'uri'
require 'public_suffix'

module Nokizaru
  module Modules
    module Crawler
      # JavaScript source crawling and URL extraction helpers
      module JavaScript
        private

        def js_crawl(result, js_links, page_url, request_headers)
          apply_adaptive_budget!(result)
          return [] if crawl_budget_exhausted?(result)

          targets = scoped_js_targets(result, js_links, page_url)
          return [] if targets.empty?

          urls = []
          mutex = Mutex.new
          each_in_threads(targets) do |js|
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
          return [] unless response.is_a?(Net::HTTPSuccess)

          found = response.body.scan(%r{https?://[\w\-.~:/?#\[\]@!$&'()*+,;=%]+})
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
          return false unless uri.host

          registrable_domain(uri.host) == registrable_domain(target_host)
        rescue StandardError
          false
        end

        def registrable_domain(host)
          normalized_host = host.to_s.downcase
          value = PublicSuffix.domain(normalized_host)
          labels = normalized_host.split('.').reject(&:empty?)
          unless value.to_s.strip.empty?
            normalized = value.to_s.downcase
            return labels.last(2).join('.') if normalized == normalized_host && labels.length > 2

            return normalized
          end

          return host.to_s.downcase if labels.length < 2

          labels.last(2).join('.')
        rescue StandardError
          labels = host.to_s.downcase.split('.').reject(&:empty?)
          return host.to_s.downcase if labels.length < 2

          labels.last(2).join('.')
        end

        def scoped_js_targets(result, js_links, page_url)
          base = URI.parse(page_url)
          links = Array(js_links).compact.uniq.select do |url|
            js_uri = URI.parse(url)
            registrable_domain(js_uri.host) == registrable_domain(base.host)
          rescue StandardError
            false
          end
          links.first(adaptive_limit(result, :max_js_targets))
        end
      end
    end
  end
end
