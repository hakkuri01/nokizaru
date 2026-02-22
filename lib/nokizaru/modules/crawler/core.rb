# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Result setup and completion helpers
      module Core
        private

        def initialize_result
          base_link_buckets.merge(extra_crawler_buckets)
        end

        def base_link_buckets
          {
            'robots_links' => [], 'sitemap_links' => [], 'css_links' => [],
            'js_links' => [], 'internal_links' => [], 'external_links' => [],
            'images' => []
          }
        end

        def extra_crawler_buckets
          { 'urls_inside_sitemap' => [], 'urls_inside_js' => [], 'stats' => {} }
        end

        def crawl_page_resources!(result, page)
          page_url = page[:url]
          result['target']['effective'] = page_url
          populate_page_links!(result, page_url, base_url_for(page_url), page[:soup])
          populate_deep_links!(result)
          result['stats'] = calculate_stats(result)
        end

        def base_url_for(page_url)
          uri = URI.parse(page_url)
          host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
          "#{uri.scheme}://#{host}"
        end

        def finalize_crawl!(ctx, result)
          print_links_preview('JavaScript Links', result['js_links'])
          print_links_preview('URLs inside JavaScript', result['urls_inside_js'])
          print_links_preview('URLs inside Sitemaps', result['urls_inside_sitemap'])
          ctx.run['modules']['crawler'] = result
          ctx.add_artifact('urls', result['stats']['total_urls'])
          Log.write('[crawler] Completed')
        end
      end
    end
  end
end
