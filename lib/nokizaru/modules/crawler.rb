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

      TIMEOUT = 10
      USER_AGENT = 'Nokizaru'
      PREVIEW_LIMIT = 8
      MAX_FETCH_WORKERS = 8
      MAX_SITEMAPS = 200
      STEP_LABELS = [
        'Looking for robots.txt',
        'Extracting robots Links',
        'Looking for sitemap.xml',
        'Extracting CSS Links',
        'Extracting JavaScript Links',
        'Extracting Internal Links',
        'Extracting External Links',
        'Extracting Image Links',
        'Crawling Sitemaps',
        'Crawling Javascripts'
      ].freeze
      STEP_LABEL_WIDTH = STEP_LABELS.map(&:length).max

      # Run this module and store normalized results in the run context
      def call(target, protocol, netloc, ctx)
        result = initialize_result

        UI.module_header('Starting Crawler...')

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

      # Initialize crawler result buckets before extraction starts
      def initialize_result
        {
          'robots_links' => [], 'sitemap_links' => [], 'css_links' => [],
          'js_links' => [], 'internal_links' => [], 'external_links' => [],
          'images' => [], 'urls_inside_sitemap' => [], 'urls_inside_js' => [],
          'stats' => {}
        }
      end

      # Fetch and parse the target document used by crawler extractors
      def fetch_main_page(target, result, ctx)
        response = http_get(target)

        unless response
          UI.line(:error, 'Failed to fetch target')
          result['error'] = 'Failed to fetch target'
          ctx.run['modules']['crawler'] = result
          return nil
        end

        unless response.is_a?(Net::HTTPSuccess)
          UI.row(:error, 'Status', response.code)
          Log.write("[crawler] Status = #{response.code}, expected 200")
          result['error'] = "HTTP status #{response.code}"
          ctx.run['modules']['crawler'] = result
          return nil
        end

        Nokogiri::HTML(response.body)
      rescue StandardError => e
        UI.line(:error, "Exception : #{e}")
        Log.write("[crawler] Exception = #{e}")
        result['error'] = e.to_s
        ctx.run['modules']['crawler'] = result
        nil
      end

      # Fetch a URL with timeouts and headers used by crawler helpers
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

      # Normalize discovered links to absolute URLs and drop unsupported schemes
      def url_filter(target, link)
        return nil if link.nil? || link.empty?
        return nil if link.start_with?('#', 'javascript:', 'mailto:')

        base = target.end_with?('/') ? target : "#{target}/"
        URI.join(base, link).to_s
      rescue StandardError
        nil
      end

      # Read robots directives and collect crawl paths plus sitemap hints
      def robots(robo_url, base_url)
        r_total = []
        sm_total = []

        response = http_get(robo_url)

        if response&.is_a?(Net::HTTPSuccess)
          response.body.each_line do |line|
            next unless line.start_with?('Disallow', 'Allow', 'Sitemap')

            url = line.split(': ', 2)[1]&.strip
            next if url.nil? || url.empty?

            filtered = url_filter(base_url, url)
            r_total << filtered if filtered
            sm_total << url if url.end_with?('xml')
          end

          step_row(:info, 'Looking for robots.txt', 'Found')
          step_row(:info, 'Extracting robots Links', r_total.uniq.length)
        elsif response&.code == '404'
          step_row(:info, 'Looking for robots.txt', 'Not Found')
        else
          step_row(:error, 'Looking for robots.txt', response&.code || 'Error')
        end

        [r_total.uniq, sm_total.uniq]
      end

      # Check default sitemap path and merge discovered sitemap locations
      def sitemap(sm_url, sm_total)
        sm_total = Array(sm_total).dup

        response = http_get(sm_url)

        if response&.is_a?(Net::HTTPSuccess)
          step_row(:info, 'Looking for sitemap.xml', 'Found')
          sm_total << sm_url
        elsif response&.code == '404'
          step_row(:info, 'Looking for sitemap.xml', 'Not Found')
        else
          step_row(:error, 'Looking for sitemap.xml', response&.code || 'Error')
        end

        sm_total.uniq
      end

      # Collect stylesheet URLs referenced by the initial response document
      def css(target, soup)
        links = []
        soup.css('link[rel="stylesheet"]').each do |tag|
          href = url_filter(target, tag['href'])
          links << href if href
        end

        step_row(:info, 'Extracting CSS Links', links.uniq.length)
        links.uniq
      end

      # Collect JavaScript asset URLs for later endpoint extraction
      def js_scan(target, soup)
        links = []
        soup.css('script[src]').each do |tag|
          src = url_filter(target, tag['src'])
          links << src if src
        end

        step_row(:info, 'Extracting JavaScript Links', links.uniq.length)
        links.uniq
      end

      # Collect links that remain within the target scope
      def internal_links(target, soup)
        links = []
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

        step_row(:info, 'Extracting Internal Links', links.uniq.length)
        links.uniq
      end

      # Collect links that point outside the target scope
      def external_links(target, soup)
        links = []
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

        step_row(:info, 'Extracting External Links', links.uniq.length)
        links.uniq
      end

      # Collect image asset URLs that can reveal hidden application paths
      def images(target, soup)
        links = []
        soup.css('img[src]').each do |tag|
          src = url_filter(target, tag['src'])
          links << src if src
        end

        step_row(:info, 'Extracting Image Links', links.uniq.length)
        links.uniq
      end

      # Fetch sitemap documents and extract URL entries for recon coverage
      def sm_crawl(sm_total)
        links = []
        sm_total = Array(sm_total).compact.map(&:strip).uniq
        return links if sm_total.empty?

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

        step_row(:info, 'Crawling Sitemaps', links.uniq.length)
        links.uniq
      end

      # Fetch JavaScript assets and extract embedded URL candidates
      def js_crawl(js_total)
        urls = []
        js_total = Array(js_total).compact.uniq
        return urls if js_total.empty?

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

        step_row(:info, 'Crawling Javascripts', urls.uniq.length)
        urls.uniq
      end

      # Print crawler status rows with stable alignment across extraction steps
      def step_row(type, label, value)
        UI.row(type, label, value, label_width: STEP_LABEL_WIDTH)
      end

      # Aggregate crawler outputs into summary statistics for reporting
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

      # Run queued tasks across a bounded worker pool
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

      # Print a short preview so large result sets stay readable
      def print_links_preview(label, links)
        links = Array(links).compact.uniq
        return if links.empty?

        UI.line(:info, "#{label} Preview")
        links.first(PREVIEW_LIMIT).each { |link| puts("    #{link}") }
        remaining = links.length - PREVIEW_LIMIT
        puts("    ... #{remaining} more") if remaining.positive?
      end

      # Normalize extracted URLs before adding them to results
      def sanitize_extracted_url(url)
        url.to_s.sub(/["'`,;\])]+\z/, '')
      end
    end
  end
end
