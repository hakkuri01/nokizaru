# frozen_string_literal: true

require 'httpx'
require 'nokogiri'
require 'public_suffix'
require_relative '../log'
require_relative '../http_result'

module Nokizaru
  module Modules
    # Lightweight on-page crawler:
    # - robots.txt + sitemap.xml discovery
    # - CSS/JS/internal/external/img extraction
    # - URL harvesting from sitemap + JS
    module Crawler
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      USER_AGENT = { 'User-Agent' => 'Nokizaru' }.freeze

      def call(target, protocol, netloc, ctx)
        result = {
          'robots_links' => [],
          'sitemap_links' => [],
          'css_links' => [],
          'js_links' => [],
          'internal_links' => [],
          'external_links' => [],
          'images' => [],
          'urls_inside_sitemap' => [],
          'urls_inside_js' => [],
          'stats' => {}
        }

        puts("\n#{Y}[!] Starting Crawler...#{W}\n\n")

        # Fetch the main page
        begin
          raw_response = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(target,
                                                                                                 ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
          http_result = HttpResult.new(raw_response)

          unless http_result.success?
            puts("#{R}[-] Failed to fetch target: #{C}#{http_result.error_message}#{W}")
            Log.write("[crawler] Error = #{http_result.error_message}")
            result['error'] = http_result.error_message
            ctx.run['modules']['crawler'] = result
            return
          end

          if http_result.status != 200
            puts("#{R}[-] #{C}Status : #{W}#{http_result.status}")
            Log.write("[crawler] Status code = #{http_result.status}, expected 200")
            result['error'] = "HTTP status #{http_result.status}"
            ctx.run['modules']['crawler'] = result
            return
          end
        rescue StandardError => e
          puts("#{R}[-] Exception : #{C}#{e}#{W}")
          Log.write("[crawler] Exception = #{e}")
          result['error'] = e.to_s
          ctx.run['modules']['crawler'] = result
          return
        end

        page = http_result.body
        soup = Nokogiri::HTML(page)

        base_url = "#{protocol}://#{netloc}"
        robots_url = "#{base_url}/robots.txt"
        sitemap_url = "#{base_url}/sitemap.xml"

        result['robots_links'], discovered_sitemaps = robots(robots_url, base_url)
        result['sitemap_links'] = sitemap(sitemap_url, discovered_sitemaps)
        result['css_links'] = css(target, soup)
        result['js_links'] = js_scan(target, soup)
        result['internal_links'] = internal_links(target, soup)
        result['external_links'] = external_links(soup)
        result['images'] = images(target, soup)

        result['urls_inside_sitemap'] = sm_crawl(result['sitemap_links'])
        result['urls_inside_js'] = js_crawl(result['js_links'])

        result['stats'] = stats(result)

        ctx.run['modules']['crawler'] = result
        ctx.add_artifact('urls', result['stats']['total_urls'])

        Log.write('[crawler] Completed')
      end

      def url_filter(target, link)
        return nil if link.nil?

        return target + link if link.start_with?('/') && !link.start_with?('//')

        return link.sub('//', 'http://') if link.start_with?('//')

        if link !~ %r{//} && link !~ %r{\.\./} && link !~ %r{\./} &&
           !link.start_with?('http://') && !link.start_with?('https://')
          return "#{target}/#{link}"
        end

        if !link.start_with?('http://') && !link.start_with?('https://')
          ret = link.sub('//', 'http://')
          ret = ret.sub('../', "#{target}/")
          ret = ret.sub('./', "#{target}/")
          return ret
        end

        link
      end

      def robots(robo_url, base_url)
        r_total = []
        sm_total = []

        print("#{G}[+] #{C}Looking for robots.txt#{W}")

        begin
          raw_response = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(robo_url,
                                                                                                 ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
          http_result = HttpResult.new(raw_response)

          unless http_result.success?
            puts("#{R}#{'['.rjust(9, '.')} Error: #{http_result.error_message} ]#{W}")
            Log.write("[crawler.robots] Error = #{http_result.error_message}")
            return [r_total, sm_total]
          end

          r_sc = http_result.status
          if r_sc == 200
            puts("#{G}#{'['.rjust(9, '.')} Found ]#{W}")
            print("#{G}[+] #{C}Extracting robots Links#{W}")

            r_page = http_result.body
            r_page.split("\n").each do |entry|
              next unless entry.start_with?('Disallow', 'Allow', 'Sitemap')

              url = entry.split(': ', 2)[1]&.strip
              next if url.nil?

              tmp = url_filter(base_url, url)
              r_total << tmp if tmp
              sm_total << url if url.end_with?('xml')
            end

            r_total.uniq!
            sm_total.uniq!
            puts("#{G}#{'['.rjust(8, '.')} #{r_total.length} ]")
          elsif r_sc == 404
            puts("#{R}#{'['.rjust(9, '.')} Not Found ]#{W}")
          else
            puts("#{R}#{'['.rjust(9, '.')} #{r_sc} ]#{W}")
          end
        rescue StandardError => e
          puts("\n#{R}[-] Exception : #{C}#{e}#{W}")
          Log.write("[crawler.robots] Exception = #{e}")
        end

        [r_total, sm_total]
      end

      def sitemap(target_url, sm_total)
        sm_total = Array(sm_total).dup
        print("#{G}[+] #{C}Looking for sitemap.xml#{W}")

        begin
          raw_response = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(target_url,
                                                                                                 ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
          http_result = HttpResult.new(raw_response)

          unless http_result.success?
            puts("#{R}#{'['.rjust(8, '.')} Error: #{http_result.error_message} ]#{W}")
            Log.write("[crawler.sitemap] Error = #{http_result.error_message}")
            return sm_total
          end

          sm_sc = http_result.status
          if sm_sc == 200
            puts("#{G}#{'['.rjust(8, '.')} Found ]#{W}")
            sm_total << target_url
          elsif sm_sc == 404
            puts("#{R}#{'['.rjust(8, '.')} Not Found ]#{W}")
          else
            puts("#{R}#{'['.rjust(8, '.')} #{sm_sc} ]#{W}")
          end
        rescue StandardError => e
          puts("\n#{R}[-] Exception : #{C}#{e}#{W}")
          Log.write("[crawler.sitemap] Exception = #{e}")
        end

        sm_total.uniq
      end

      def css(target, soup)
        css_total = []
        print("#{G}[+] #{C}Extracting CSS Links#{W}")
        soup.css('link[rel="stylesheet"]').each do |tag|
          href = url_filter(target, tag['href'])
          css_total << href if href
        end
        css_total.uniq!
        puts("#{G}#{'['.rjust(13, '.')} #{css_total.length} ]")
        css_total
      end

      def js_scan(target, soup)
        js_total = []
        print("#{G}[+] #{C}Extracting JavaScript Links#{W}")
        soup.css('script[src]').each do |tag|
          src = url_filter(target, tag['src'])
          js_total << src if src
        end
        js_total.uniq!
        puts("#{G}#{'['.rjust(5, '.')} #{js_total.length} ]")
        js_total
      end

      def internal_links(target, soup)
        int_total = []
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
            u = URI(href)
            next unless u.host
            next if host && PublicSuffix.domain(u.host) != host
          rescue StandardError
            next
          end
          int_total << href
        end

        int_total.uniq!
        puts("#{G}#{'['.rjust(11, '.')} #{int_total.length} ]")
        int_total
      end

      def external_links(soup)
        ext_total = []
        print("#{G}[+] #{C}Extracting External Links#{W}")
        soup.css('a[href]').each do |tag|
          href = tag['href']
          next unless href
          next unless href.start_with?('http://', 'https://')

          ext_total << href
        end
        ext_total.uniq!
        puts("#{G}#{'['.rjust(11, '.')} #{ext_total.length} ]")
        ext_total
      end

      def images(target, soup)
        img_total = []
        print("#{G}[+] #{C}Extracting Image Links#{W}")
        soup.css('img[src]').each do |tag|
          src = url_filter(target, tag['src'])
          img_total << src if src
        end
        img_total.uniq!
        puts("#{G}#{'['.rjust(14, '.')} #{img_total.length} ]")
        img_total
      end

      def sm_crawl(sm_total)
        links = []
        sm_total = Array(sm_total).compact.uniq
        return links if sm_total.empty?

        print("#{G}[+] #{C}Crawling Sitemaps#{W}")
        sm_total.each do |sm|
          raw_response = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(sm,
                                                                                                 ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
          http_result = HttpResult.new(raw_response)

          next unless http_result.success? && http_result.status == 200

          xml = http_result.body
          doc = Nokogiri::XML(xml)
          doc.remove_namespaces!
          doc.xpath('//url/loc').each do |loc|
            u = loc.text.to_s.strip
            links << u unless u.empty?
          end
          # sitemap index
          doc.xpath('//sitemap/loc').each do |loc|
            u = loc.text.to_s.strip
            sm_total << u unless u.empty?
          end
        rescue StandardError => e
          Log.write("[crawler.sm_crawl] Exception = #{e}")
        end

        links.uniq!
        puts("#{G}#{'['.rjust(16, '.')} #{links.length} ]")
        links
      end

      def js_crawl(js_total)
        urls = []
        js_total = Array(js_total).compact.uniq
        return urls if js_total.empty?

        print("#{G}[+] #{C}Crawling JS#{W}")
        js_total.each do |js|
          raw_response = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(js,
                                                                                                 ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
          http_result = HttpResult.new(raw_response)

          next unless http_result.success? && http_result.status == 200

          body = http_result.body
          body.scan(%r{https?://[\w\-._~:/?#\[\]@!$&'()*+,;=%]+}) do |m|
            urls << m
          end
        rescue StandardError => e
          Log.write("[crawler.js_crawl] Exception = #{e}")
        end
        urls.uniq!
        puts("#{G}#{'['.rjust(22, '.')} #{urls.length} ]")
        urls
      end

      def stats(result)
        all = []
        %w[robots_links sitemap_links css_links js_links internal_links external_links images urls_inside_sitemap
           urls_inside_js].each do |k|
          all.concat(Array(result[k]))
        end
        all.uniq!

        {
          'robots_count' => Array(result['robots_links']).length,
          'sitemap_count' => Array(result['sitemap_links']).length,
          'css_count' => Array(result['css_links']).length,
          'js_count' => Array(result['js_links']).length,
          'internal_count' => Array(result['internal_links']).length,
          'external_count' => Array(result['external_links']).length,
          'images_count' => Array(result['images']).length,
          'sitemap_url_count' => Array(result['urls_inside_sitemap']).length,
          'js_url_count' => Array(result['urls_inside_js']).length,
          'total_unique' => all.length,
          'total_urls' => all
        }
      end
    end
  end
end
