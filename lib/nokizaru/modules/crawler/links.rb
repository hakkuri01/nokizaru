# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Link extraction helpers for initial page data
      module Links
        private

        def populate_page_links!(result, page_url, base_url, soup)
          robots_links, discovered = robots("#{base_url}/robots.txt", base_url)
          result['robots_links'] = robots_links
          result['sitemap_links'] = sitemap("#{base_url}/sitemap.xml", discovered)
          result['css_links'] = collect_links(soup, 'link[rel="stylesheet"]', 'href', page_url, 'Extracting CSS Links')
          result['js_links'] = collect_links(soup, 'script[src]', 'src', page_url, 'Extracting JavaScript Links')
          result['internal_links'] = internal_links(page_url, soup)
          result['external_links'] = external_links(page_url, soup)
          result['images'] = collect_links(soup, 'img[src]', 'src', page_url, 'Extracting Image Links')
        end

        def robots(url, base_url)
          response = http_get(url)
          return handle_missing_robots(response) unless response.is_a?(Net::HTTPSuccess)

          links, sitemaps = parse_robots_body(response.body, base_url)
          step_row(:info, 'Looking for robots.txt', 'Found')
          step_row(:info, 'Extracting robots Links', links.length)
          [links, sitemaps]
        end

        def parse_robots_body(body, base_url)
          links = []
          sitemaps = []
          body.each_line { |line| append_robots_line(line, base_url, links, sitemaps) }
          [links.uniq, sitemaps.uniq]
        end

        def append_robots_line(line, base_url, links, sitemaps)
          parsed = parse_robots_line(line, base_url)
          return unless parsed

          links << parsed[:url] if parsed[:url]
          sitemaps << parsed[:sitemap] if parsed[:sitemap]
        end

        def handle_missing_robots(response)
          status = response&.code
          label = status == '404' ? 'Not Found' : (status || 'Error')
          level = status == '404' ? :info : :error
          step_row(level, 'Looking for robots.txt', label)
          [[], []]
        end

        def parse_robots_line(line, base_url)
          return nil unless line.start_with?('Disallow', 'Allow', 'Sitemap')

          value = line.split(': ', 2)[1]&.strip
          return nil if value.to_s.empty?

          { url: url_filter(base_url, value), sitemap: value.end_with?('xml') ? value : nil }
        end

        def sitemap(url, discovered)
          links = Array(discovered).dup
          response = http_get(url)
          apply_sitemap_status(response, url, links)
          links.uniq
        end

        def apply_sitemap_status(response, sitemap_url, links)
          if response.is_a?(Net::HTTPSuccess)
            step_row(:info, 'Looking for sitemap.xml', 'Found')
            links << sitemap_url
            return
          end

          status = response&.code == '404' ? 'Not Found' : (response&.code || 'Error')
          level = status == 'Not Found' ? :info : :error
          step_row(level, 'Looking for sitemap.xml', status)
        end

        def collect_links(soup, selector, attr, target, label)
          links = soup.css(selector).filter_map { |tag| url_filter(target, tag[attr]) }.uniq
          step_row(:info, label, links.length)
          links
        end

        def internal_links(target, soup)
          host = target_public_suffix_domain(target)
          links = soup.css('a[href]').filter_map { |tag| internal_link(target, host, tag['href']) }.uniq
          step_row(:info, 'Extracting Internal Links', links.length)
          links
        end

        def external_links(target, soup)
          host = target_public_suffix_domain(target)
          links = soup.css('a[href]').filter_map { |tag| external_link(host, tag['href']) }.uniq
          step_row(:info, 'Extracting External Links', links.length)
          links
        end
      end
    end
  end
end
