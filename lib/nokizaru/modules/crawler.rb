# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require 'nokogiri'
require 'public_suffix'
require 'set'
require_relative '../log'

module Nokizaru
  module Modules
    module Crawler
      module_function

      R = "\e[31m"
      G = "\e[32m"
      C = "\e[36m"
      W = "\e[0m"
      Y = "\e[33m"

      TIMEOUT = 10
      USER_AGENT = 'Nokizaru'
      PREVIEW_LIMIT = 8
      MAX_FETCH_WORKERS = 8
      MAX_SITEMAPS = 200

      def call(target, protocol, netloc, ctx)
        result = initialize_result

        puts("\n#{Y}[!] Starting Crawler...#{W}\n\n")

        base_url = "#{protocol}://#{netloc}"

        # Fetch main page
        soup = fetch_main_page(target, result, ctx)
        return if soup.nil?

        # Crawl resources
        result['robots_links'], discovered_sitemaps = robots("#{base_url}/robots.txt", base_url)
        result['sitemap_links'] = sitemap("#{base_url}/sitemap.xml", discovered_sitemaps)
        result['css_links'] = css(target, soup)
        result['js_links'] = js_scan(target, soup)
        result['internal_links'] = internal_links(target, soup)
        result['external_links'] = external_links(target, soup)
        result['images'] = images(target, soup)

        result['urls_inside_sitemap'] = sm_crawl(result['sitemap_links'])
        result['urls_inside_js'] = js_crawl(result['js_links'])

        result['stats'] = calculate_stats(result)

        print_links_preview('JavaScript Links', result['js_links'])
        print_links_preview('URLs inside JavaScript', result['urls_inside_js'])
        print_links_preview('URLs inside Sitemaps', result['urls_inside_sitemap'])

        ctx.run['modules']['crawler'] = result
        ctx.add_artifact('urls', result['stats']['total_urls'])

        Log.write('[crawler] Completed')
      end

      def initialize_result
        {
          'robots_links' => [], 'sitemap_links' => [], 'css_links' => [],
          'js_links' => [], 'internal_links' => [], 'external_links' => [],
          'images' => [], 'urls_inside_sitemap' => [], 'urls_inside_js' => [],
          'stats' => {}
        }
      end

      def fetch_main_page(target, result, ctx)
        response = http_get(target)

        unless response
          puts("#{R}[-] Failed to fetch target#{W}")
          result['error'] = 'Failed to fetch target'
          ctx.run['modules']['crawler'] = result
          return nil
        end

        unless response.is_a?(Net::HTTPSuccess)
          puts("#{R}[-] #{C}Status : #{W}#{response.code}")
          Log.write("[crawler] Status = #{response.code}, expected 200")
          result['error'] = "HTTP status #{response.code}"
          ctx.run['modules']['crawler'] = result
          return nil
        end

        Nokogiri::HTML(response.body)
      rescue StandardError => e
        puts("#{R}[-] Exception : #{C}#{e}#{W}")
        Log.write("[crawler] Exception = #{e}")
        result['error'] = e.to_s
        ctx.run['modules']['crawler'] = result
        nil
      end

      def http_get(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = USER_AGENT
        request['Accept'] = '*/*'

        http.request(request)
      rescue StandardError => e
        Log.write("[crawler] HTTP error for #{url}: #{e.message}")
        nil
      end

      def url_filter(target, link)
        return nil if link.nil? || link.empty?
        return nil if link.start_with?('#', 'javascript:', 'mailto:')

        base = target.end_with?('/') ? target : "#{target}/"
        URI.join(base, link).to_s
      rescue StandardError
        nil
      end

      def robots(robo_url, base_url)
        r_total = []
        sm_total = []

        print("#{G}[+] #{C}Looking for robots.txt#{W}")

        response = http_get(robo_url)

        if response&.is_a?(Net::HTTPSuccess)
          puts("#{G}#{'['.rjust(9, '.')} Found ]#{W}")
          print("#{G}[+] #{C}Extracting robots Links#{W}")

          response.body.each_line do |line|
            next unless line.start_with?('Disallow', 'Allow', 'Sitemap')

            url = line.split(': ', 2)[1]&.strip
            next if url.nil? || url.empty?

            filtered = url_filter(base_url, url)
            r_total << filtered if filtered
            sm_total << url if url.end_with?('xml')
          end

          puts("#{G}#{'['.rjust(8, '.')} #{r_total.uniq.length} ]")
        elsif response&.code == '404'
          puts("#{R}#{'['.rjust(9, '.')} Not Found ]#{W}")
        else
          puts("#{R}#{'['.rjust(9, '.')} #{response&.code || 'Error'} ]#{W}")
        end

        [r_total.uniq, sm_total.uniq]
      end

      def sitemap(sm_url, sm_total)
        sm_total = Array(sm_total).dup

        print("#{G}[+] #{C}Looking for sitemap.xml#{W}")

        response = http_get(sm_url)

        if response&.is_a?(Net::HTTPSuccess)
          puts("#{G}#{'['.rjust(8, '.')} Found ]#{W}")
          sm_total << sm_url
        elsif response&.code == '404'
          puts("#{R}#{'['.rjust(8, '.')} Not Found ]#{W}")
        else
          puts("#{R}#{'['.rjust(8, '.')} #{response&.code || 'Error'} ]#{W}")
        end

        sm_total.uniq
      end

      def css(target, soup)
        links = []
        print("#{G}[+] #{C}Extracting CSS Links#{W}")

        soup.css('link[rel="stylesheet"]').each do |tag|
          href = url_filter(target, tag['href'])
          links << href if href
        end

        puts("#{G}#{'['.rjust(13, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def js_scan(target, soup)
        links = []
        print("#{G}[+] #{C}Extracting JavaScript Links#{W}")

        soup.css('script[src]').each do |tag|
          src = url_filter(target, tag['src'])
          links << src if src
        end

        puts("#{G}#{'['.rjust(5, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def internal_links(target, soup)
        links = []
        print("#{G}[+] #{C}Extracting Internal Links#{W}")

        host = begin
          PublicSuffix.domain(URI(target).host)
        rescue StandardError
          nil
        end

        soup.css('a[href]').each do |tag|
          href = url_filter(target, tag['href'])
          next unless href

          begin
            uri = URI(href)
            next unless uri.host
            next if host && PublicSuffix.domain(uri.host) != host
          rescue StandardError
            next
          end

          links << href
        end

        puts("#{G}#{'['.rjust(11, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def external_links(target, soup)
        links = []
        print("#{G}[+] #{C}Extracting External Links#{W}")

        host = begin
          PublicSuffix.domain(URI(target).host)
        rescue StandardError
          nil
        end

        soup.css('a[href]').each do |tag|
          href = tag['href']
          next unless href&.start_with?('http://', 'https://')

          begin
            uri = URI(href)
            next unless uri.host
            next if host && PublicSuffix.domain(uri.host) == host
          rescue StandardError
            next
          end

          links << href
        end

        puts("#{G}#{'['.rjust(11, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def images(target, soup)
        links = []
        print("#{G}[+] #{C}Extracting Image Links#{W}")

        soup.css('img[src]').each do |tag|
          src = url_filter(target, tag['src'])
          links << src if src
        end

        puts("#{G}#{'['.rjust(14, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def sm_crawl(sm_total)
        links = []
        sm_total = Array(sm_total).compact.map(&:strip).uniq
        return links if sm_total.empty?

        print("#{G}[+] #{C}Crawling Sitemaps#{W}")

        seen_sitemaps = Set.new
        pending = sm_total.select { |url| url.downcase.end_with?('.xml') }

        while pending.any? && seen_sitemaps.length < MAX_SITEMAPS
          batch = pending.reject { |url| seen_sitemaps.include?(url) }
          break if batch.empty?

          batch = batch.first(MAX_SITEMAPS - seen_sitemaps.length)
          batch.each { |url| seen_sitemaps.add(url) }

          discovered_sitemaps = []
          mutex = Mutex.new

          each_in_threads(batch) do |sm|
            response = http_get(sm)
            next unless response&.is_a?(Net::HTTPSuccess)

            begin
              doc = Nokogiri::XML(response.body)
              doc.remove_namespaces!

              page_links = doc.xpath('//url/loc').map { |loc| loc.text.to_s.strip }.reject(&:empty?)
              child_sitemaps = doc.xpath('//sitemap/loc').map { |loc| loc.text.to_s.strip }
                                  .select { |url| !url.empty? && url.downcase.end_with?('.xml') }

              mutex.synchronize do
                links.concat(page_links)
                discovered_sitemaps.concat(child_sitemaps)
              end
            rescue StandardError => e
              Log.write("[crawler.sm_crawl] Exception = #{e}")
            end
          end

          pending = discovered_sitemaps.uniq
        end

        puts("#{G}#{'['.rjust(16, '.')} #{links.uniq.length} ]")
        links.uniq
      end

      def js_crawl(js_total)
        urls = []
        js_total = Array(js_total).compact.uniq
        return urls if js_total.empty?

        print("#{G}[+] #{C}Crawling JS#{W}")

        mutex = Mutex.new
        each_in_threads(js_total) do |js|
          response = http_get(js)
          next unless response&.is_a?(Net::HTTPSuccess)

          found = response.body.scan(%r{https?://[\w\-.~:/?#\[\]@!$&'()*+,;=%]+})
          found.map! { |url| sanitize_extracted_url(url) }
          found.reject!(&:empty?)
          mutex.synchronize { urls.concat(found) }
        rescue StandardError => e
          Log.write("[crawler.js_crawl] Exception = #{e}")
        end

        puts("#{G}#{'['.rjust(22, '.')} #{urls.uniq.length} ]")
        urls.uniq
      end

      def calculate_stats(result)
        all = %w[robots_links sitemap_links css_links js_links internal_links
                 external_links images urls_inside_sitemap urls_inside_js]
              .flat_map { |k| Array(result[k]) }
              .uniq

        {
          'robots_count' => result['robots_links'].length,
          'sitemap_count' => result['sitemap_links'].length,
          'css_count' => result['css_links'].length,
          'js_count' => result['js_links'].length,
          'internal_count' => result['internal_links'].length,
          'external_count' => result['external_links'].length,
          'images_count' => result['images'].length,
          'sitemap_url_count' => result['urls_inside_sitemap'].length,
          'js_url_count' => result['urls_inside_js'].length,
          'total_unique' => all.length,
          'total_urls' => all
        }
      end

      def each_in_threads(items)
        queue = Queue.new
        items.each { |item| queue << item }

        workers = [items.length, MAX_FETCH_WORKERS].min
        threads = Array.new(workers) do
          Thread.new do
            loop do
              item = begin
                queue.pop(true)
              rescue ThreadError
                nil
              end

              break if item.nil?

              yield(item)
            end
          end
        end

        threads.each(&:join)
      end

      def print_links_preview(label, links)
        links = Array(links).compact.uniq
        return if links.empty?

        puts("#{G}[+] #{C}#{label} Preview#{W}")
        links.first(PREVIEW_LIMIT).each { |link| puts("    #{W}#{link}") }
        remaining = links.length - PREVIEW_LIMIT
        puts("    #{Y}... #{remaining} more#{W}") if remaining.positive?
      end

      def sanitize_extracted_url(url)
        url.to_s.sub(/["'`,;\])]+\z/, '')
      end
    end
  end
end
