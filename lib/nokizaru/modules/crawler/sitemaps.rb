# frozen_string_literal: true

require 'nokogiri'
require 'set'

module Nokizaru
  module Modules
    module Crawler
      # Sitemap crawling and recursive expansion helpers
      module Sitemaps
        private

        def populate_deep_links!(result, page_url, request_headers)
          result['urls_inside_sitemap'] = sm_crawl(result, result['sitemap_links'], request_headers)
          result['urls_inside_js'] = js_crawl(result, result['js_links'], page_url, request_headers)
        end

        def sm_crawl(result, sitemap_links, request_headers)
          apply_adaptive_budget!(result)
          return [] if crawl_budget_exhausted?(result)

          state = init_sitemap_state(sitemap_links)
          return [] if state[:pending].empty?

          crawl_sitemap_graph(result, state, request_headers)
          links = state[:links].uniq
          step_row(:info, 'Crawling Sitemaps', links.length)
          links
        end

        def init_sitemap_state(sitemap_links)
          normalized = Array(sitemap_links).compact.map(&:strip).uniq
          {
            links: [],
            pending: normalized.select { |url| url.downcase.end_with?('.xml') },
            seen: Set.new
          }
        end

        def crawl_sitemap_graph(result, state, request_headers)
          while state[:pending].any? && state[:seen].length < adaptive_limit(result, :max_sitemaps)
            apply_adaptive_budget!(result)
            break if crawl_budget_exhausted?(result)
            break if state[:links].length >= adaptive_limit(result, :max_sitemap_urls)

            batch = next_sitemap_batch(result, state)
            break if batch.empty?

            batch.each { |url| state[:seen].add(url) }
            state[:pending] = crawl_sitemap_batch(result, batch, state[:links], request_headers)
          end
        end

        def next_sitemap_batch(result, state)
          remaining = [adaptive_limit(result, :max_sitemaps) - state[:seen].length, 0].max
          fresh = state[:pending].reject { |url| state[:seen].include?(url) }
          fresh.first(remaining)
        end

        def crawl_sitemap_batch(result, batch, links, request_headers)
          discovered = []
          mutex = Mutex.new
          each_in_threads(batch) do |sitemap_url|
            next if crawl_budget_exhausted?(result)

            page_links, child_sitemaps = parse_sitemap_document(result, sitemap_url, request_headers)
            mutex.synchronize do
              links.concat(page_links)
              links.uniq!
              max_sitemap_urls = adaptive_limit(result, :max_sitemap_urls)
              links.slice!(max_sitemap_urls..) if links.length > max_sitemap_urls

              discovered.concat(child_sitemaps)
              discovered.uniq!
              max_sitemaps = adaptive_limit(result, :max_sitemaps)
              discovered.slice!(max_sitemaps..) if discovered.length > max_sitemaps
            end
          end
          discovered.uniq
        end

        def parse_sitemap_document(result, sitemap_url, request_headers)
          return [[], []] if crawl_budget_exhausted?(result)

          response = http_get(sitemap_url, request_headers: request_headers)
          return [[], []] unless response.is_a?(Net::HTTPSuccess)

          doc = Nokogiri::XML(response.body)
          doc.remove_namespaces!
          [xml_links(doc, '//url/loc'), xml_links(doc, '//sitemap/loc').select { |url| url.downcase.end_with?('.xml') }]
        rescue StandardError => e
          Log.write("[crawler.sm_crawl] Exception = #{e}")
          [[], []]
        end

        def xml_links(doc, xpath)
          doc.xpath(xpath).map { |node| node.text.to_s.strip }.reject(&:empty?)
        end
      end
    end
  end
end
