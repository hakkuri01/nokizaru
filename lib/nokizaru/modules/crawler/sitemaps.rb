# frozen_string_literal: true

require 'nokogiri'
require 'stringio'
require 'zlib'

module Nokizaru
  module Modules
    module Crawler
      module Sitemaps
        private

        def populate_deep_links!(result, page_url, request_headers)
          result['urls_inside_sitemap'] = sm_crawl(result, result['sitemap_links'], page_url, request_headers)
          result['urls_inside_js'] = js_crawl(result, result['js_links'], page_url, request_headers)
        end

        def sm_crawl(result, sitemap_links, page_url, request_headers)
          apply_adaptive_budget!(result)
          return [] if crawl_budget_exhausted?(result)

          state = init_sitemap_state(sitemap_links, URI.parse(page_url).host)
          return [] if state[:pending].empty?

          crawl_sitemap_graph(result, state, request_headers)
          result['sitemap_links'] = cap_links(state[:sitemaps], adaptive_limit(result, :max_sitemap_links))
          links = state[:links].uniq
          step_row(:info, 'Crawling Sitemaps', links.length)
          links
        end

        def init_sitemap_state(sitemap_links, target_host)
          normalized = Array(sitemap_links).compact.map(&:strip).uniq
          {
            links: [],
            sitemaps: normalized,
            pending: scoped_sitemap_candidates(normalized, target_host),
            target_host: target_host,
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
            state[:pending] = crawl_sitemap_batch(result, batch, state, request_headers)
          end
        end

        def next_sitemap_batch(result, state)
          remaining = [adaptive_limit(result, :max_sitemaps) - state[:seen].length, 0].max
          fresh = state[:pending].reject { |url| state[:seen].include?(url) }
          fresh.first(remaining)
        end

        def crawl_sitemap_batch(result, batch, state, request_headers)
          discovered = []
          mutex = Mutex.new
          each_concurrently(batch) do |sitemap_url|
            next if crawl_budget_exhausted?(result)

            page_links, child_sitemaps = parse_sitemap_document(result, sitemap_url, request_headers)
            mutex.synchronize { merge_sitemap_batch!(result, state, page_links, child_sitemaps, discovered) }
          end
          discovered.uniq
        end

        def merge_sitemap_batch!(result, state, page_links, child_sitemaps, discovered)
          state[:links] = cap_links(state[:links] + page_links, adaptive_limit(result, :max_sitemap_urls))
          state[:sitemaps] = cap_links(state[:sitemaps] + child_sitemaps, adaptive_limit(result, :max_sitemap_links))
          discovered.concat(scoped_sitemap_candidates(child_sitemaps, state[:target_host]))
          discovered.replace(cap_links(discovered, adaptive_limit(result, :max_sitemaps)))
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
          uri = URI.parse(url.to_s)
          path = uri.path.to_s.downcase
          uri.is_a?(URI::HTTP) && uri.host && path.end_with?('.xml', '.xml.gz')
        rescue StandardError
          false
        end

        def scoped_sitemap_candidates(urls, target_host)
          # Security: target-controlled sitemap URLs stay as intel but cannot expand fetch scope
          Array(urls).select { |url| sitemap_candidate?(url) && same_scope_url?(url, target_host) }
        end

        def sitemap_body(response, sitemap_url)
          body = Nokizaru::HTTPClient.response_body(response)
          return body if body.empty?

          return body unless gzip_sitemap_body?(body)

          Zlib::GzipReader.new(StringIO.new(body)).read
        rescue StandardError => e
          Log.write("[crawler.sm_crawl] Failed to decode gzip sitemap #{sitemap_url}: #{e.message}")
          ''
        end

        def gzip_sitemap_body?(body)
          body.to_s.b.start_with?("\x1F\x8B".b)
        end

        def log_sitemap_fetch_skip(sitemap_url, fetch)
          code = Nokizaru::HTTPClient.status_code(fetch[:response])
          status = code.positive? ? code : fetch[:stop_reason]
          Log.write("[crawler.sm_crawl] Skipping sitemap #{sitemap_url} (#{status})")
        end

        def xml_links(doc, xpath)
          doc.xpath(xpath).map { |node| node.text.to_s.strip }.reject(&:empty?)
        end
      end
    end
  end
end
