# frozen_string_literal: true

require 'nokogiri'
require 'set'

module Nokizaru
  module Modules
    module Crawler
      # Sitemap crawling and recursive expansion helpers
      module Sitemaps
        private

        def populate_deep_links!(result)
          result['urls_inside_sitemap'] = sm_crawl(result['sitemap_links'])
          result['urls_inside_js'] = js_crawl(result['js_links'])
        end

        def sm_crawl(sitemap_links)
          state = init_sitemap_state(sitemap_links)
          return [] if state[:pending].empty?

          crawl_sitemap_graph(state)
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

        def crawl_sitemap_graph(state)
          while state[:pending].any? && state[:seen].length < Crawler::MAX_SITEMAPS
            batch = next_sitemap_batch(state)
            break if batch.empty?

            batch.each { |url| state[:seen].add(url) }
            state[:pending] = crawl_sitemap_batch(batch, state[:links])
          end
        end

        def next_sitemap_batch(state)
          remaining = Crawler::MAX_SITEMAPS - state[:seen].length
          fresh = state[:pending].reject { |url| state[:seen].include?(url) }
          fresh.first(remaining)
        end

        def crawl_sitemap_batch(batch, links)
          discovered = []
          each_in_threads(batch) do |sitemap_url|
            page_links, child_sitemaps = parse_sitemap_document(sitemap_url)
            links.concat(page_links)
            discovered.concat(child_sitemaps)
          end
          discovered.uniq
        end

        def parse_sitemap_document(sitemap_url)
          response = http_get(sitemap_url)
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
