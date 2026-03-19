# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Result setup and completion helpers
      module Core
        private

        def initialize_result
          {
            'robots_links' => [],
            'sitemap_links' => [],
            'css_links' => [],
            'js_links' => [],
            'internal_links' => [],
            'external_links' => [],
            'images' => [],
            'urls_inside_sitemap' => [],
            'urls_inside_js' => [],
            'stats' => {},
            '__control__' => crawler_control_state
          }
        end

        def crawl_page_resources!(result, page)
          page_url = page[:url]
          result['target']['effective'] = page_url
          request_headers = page[:request_headers] || {}
          populate_page_links!(result, page_url, base_url_for(page_url), page[:soup], request_headers)
          apply_adaptive_budget!(result)
          populate_deep_links!(result, page_url, request_headers)
          result['high_signal_urls'] = high_signal_urls(result)
          result['stats'] = calculate_stats(result)
          append_crawl_control_stats!(result)
        end

        def base_url_for(page_url)
          uri = URI.parse(page_url)
          host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
          "#{uri.scheme}://#{host}"
        end

        def finalize_crawl!(ctx, result)
          result.delete('__control__')
          print_links_preview('JavaScript Links', result['js_links'])
          print_links_preview('URLs inside JavaScript', result['urls_inside_js'])
          print_links_preview('URLs inside Sitemaps', result['urls_inside_sitemap'])
          ctx.run['modules']['crawler'] = result
          ctx.add_artifact('urls', result['stats']['total_urls'])
          ctx.add_artifact('high_signal_urls', result['high_signal_urls']) if Array(result['high_signal_urls']).any?
          Log.write('[crawler] Completed')
        end

        def crawler_control_state
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          {
            started_at: started_at,
            deadline_at: started_at + Crawler::MAX_WALL_CLOCK_S,
            degraded: false,
            notes: [],
            limits: {
              max_sitemaps: Crawler::MAX_SITEMAPS,
              max_sitemap_links: Crawler::MAX_SITEMAP_LINKS,
              max_sitemap_urls: Crawler::MAX_SITEMAP_URLS,
              max_js_targets: Crawler::MAX_JS_TARGETS,
              max_js_urls_total: Crawler::MAX_JS_URLS_TOTAL
            }
          }
        end

        def crawler_control(result)
          result['__control__'] ||= crawler_control_state
        end

        def adaptive_limit(result, key)
          crawler_control(result).dig(:limits, key)
        end

        def crawl_budget_exhausted?(result)
          exhausted = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= crawler_control(result)[:deadline_at]
          mark_budget_exhausted!(result) if exhausted
          exhausted
        end

        def apply_adaptive_budget!(result)
          return if crawl_budget_exhausted?(result)

          control = crawler_control(result)
          return if control[:degraded]

          return unless heavy_crawl_surface?(result)

          control[:degraded] = true
          control[:notes] << 'heavy_target'
          control[:limits][:max_sitemaps] = Crawler::DEGRADED_MAX_SITEMAPS
          control[:limits][:max_sitemap_links] = Crawler::DEGRADED_MAX_SITEMAP_LINKS
          control[:limits][:max_sitemap_urls] = Crawler::DEGRADED_MAX_SITEMAP_URLS
          control[:limits][:max_js_targets] = Crawler::DEGRADED_MAX_JS_TARGETS
          control[:limits][:max_js_urls_total] = Crawler::DEGRADED_MAX_JS_URLS_TOTAL
          Log.write('[crawler] Applying degraded crawl budget for heavy target surface')
        end

        def heavy_crawl_surface?(result)
          Array(result['internal_links']).length >= Crawler::HEAVY_INTERNAL_LINKS_THRESHOLD ||
            Array(result['js_links']).length >= Crawler::HEAVY_JS_LINKS_THRESHOLD ||
            Array(result['robots_links']).length >= Crawler::HEAVY_ROBOTS_LINKS_THRESHOLD
        end

        def append_crawl_control_stats!(result)
          control = crawler_control(result)
          result['stats']['crawl_mode'] = control[:degraded] ? 'degraded' : 'standard'
          result['stats']['crawl_notes'] = control[:notes].dup
        end

        def mark_budget_exhausted!(result)
          control = crawler_control(result)
          return if control[:notes].include?('wall_clock_budget_exhausted')

          control[:notes] << 'wall_clock_budget_exhausted'
          Log.write('[crawler] Wall-clock budget exhausted; truncating deep crawl')
        end
      end
    end
  end
end
