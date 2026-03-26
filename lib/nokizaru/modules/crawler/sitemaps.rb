# frozen_string_literal: true

require 'nokogiri'
require 'set'
require 'stringio'
require 'zlib'

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
            pending: normalized.select { |url| sitemap_candidate?(url) },
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

          fetch = fetch_following_same_scope_redirects(sitemap_url, request_headers: request_headers)
          response = fetch[:response]
          unless http_success?(response)
            log_sitemap_fetch_skip(sitemap_url, fetch)
            return [[], []]
          end

          doc = Nokogiri::XML(sitemap_body(response, fetch[:effective_url] || sitemap_url))
          doc.remove_namespaces!
          [xml_links(doc, '//url/loc'), xml_links(doc, '//sitemap/loc').select { |url| sitemap_candidate?(url) }]
        rescue StandardError => e
          Log.write("[crawler.sm_crawl] Exception = #{e}")
          [[], []]
        end

        def sitemap_candidate?(url)
          lowered = url.to_s.downcase
          lowered.end_with?('.xml') || lowered.end_with?('.xml.gz')
        end

        def sitemap_body(response, sitemap_url)
          body = response.body.to_s
          return body if body.empty?

          return body unless gzip_sitemap_body?(response, sitemap_url)

          Zlib::GzipReader.new(StringIO.new(body)).read
        rescue StandardError => e
          Log.write("[crawler.sm_crawl] Failed to decode gzip sitemap #{sitemap_url}: #{e.message}")
          ''
        end

        def gzip_sitemap_body?(response, sitemap_url)
          encoding = response['content-encoding'].to_s.downcase
          encoding.include?('gzip') || sitemap_url.to_s.downcase.end_with?('.gz')
        rescue StandardError
          sitemap_url.to_s.downcase.end_with?('.gz')
        end

        def log_sitemap_fetch_skip(sitemap_url, fetch)
          status = fetch[:response]&.code || fetch[:stop_reason]
          Log.write("[crawler.sm_crawl] Skipping sitemap #{sitemap_url} (#{status})")
        end

        def xml_links(doc, xpath)
          doc.xpath(xpath).map { |node| node.text.to_s.strip }.reject(&:empty?)
        end
      end
    end
  end
end
