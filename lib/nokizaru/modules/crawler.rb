# frozen_string_literal: true

require 'httpx'
require 'nokogiri'
require 'public_suffix'
require_relative 'export'
require_relative '../log'

module Nokizaru
  module Modules
    module Crawler
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      USER_AGENT = { 'User-Agent' => 'Nokizaru' }.freeze

      def call(target, protocol, netloc, output, data)
        r_total = []
        sm_total = []
        css_total = []
        js_total = []
        int_total = []
        ext_total = []
        img_total = []
        sm_crawl_total = []
        js_crawl_total = []
        total = []

        puts("\n#{Y}[!] Starting Crawler...#{W}\n\n")

        begin
          rqst = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(target, verify: false)
        rescue StandardError => exc
          puts("#{R}[-] Exception : #{C}#{exc}#{W}")
          Log.write("[crawler] Exception = #{exc}")
          return
        end

        status = rqst.status
        if status == 200
          page = rqst.to_s
          soup = Nokogiri::HTML(page)
          r_url = "#{protocol}://#{netloc}/robots.txt"
          sm_url = "#{protocol}://#{netloc}/sitemap.xml"
          base_url = "#{protocol}://#{netloc}"

          robots(r_url, r_total, sm_total, base_url, data, output)
          sitemap(sm_url, sm_total, data, output)
          css(target, css_total, data, soup, output)
          js_scan(target, js_total, data, soup, output)
          internal_links(target, int_total, data, soup, output)
          external_links(target, ext_total, data, soup, output)
          images(target, img_total, data, soup, output)
          sm_crawl(data, sm_crawl_total, sm_total, sm_url, output)
          js_crawl(data, js_crawl_total, js_total, output)

          stats(output, r_total, sm_total, css_total, js_total,
                int_total, ext_total, img_total, sm_crawl_total,
                js_crawl_total, total, data, soup)
          Log.write('[crawler] Completed')
        else
          puts("#{R}[-] #{C}Status : #{W}#{status}")
          Log.write("[crawler] Status code = #{status}, expected 200")
        end
      end

      def url_filter(target, link)
        return nil if link.nil?

        if link.start_with?('/') && !link.start_with?('//')
          return target + link
        end

        if link.start_with?('//')
          return link.sub('//', 'http://')
        end

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

      def robots(robo_url, r_total, sm_total, base_url, data, output)
        print("#{G}[+] #{C}Looking for robots.txt#{W}")

        begin
          r_rqst = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(robo_url, verify: false)
          r_sc = r_rqst.status
          if r_sc == 200
            puts("#{G}#{'['.rjust(9, '.')} Found ]#{W}")
            print("#{G}[+] #{C}Extracting robots Links#{W}")

            r_page = r_rqst.to_s
            r_page.split("\n").each do |entry|
              next unless entry.start_with?('Disallow', 'Allow', 'Sitemap')

              url = entry.split(': ', 2)[1]&.strip
              next if url.nil?

              tmp = url_filter(base_url, url)
              r_total << tmp if tmp
              sm_total << url if url.end_with?('xml')
            end

            r_total.uniq!
            puts("#{G}#{'['.rjust(8, '.')} #{r_total.length} ]")
            exporter(data, output, r_total, 'robots')
          elsif r_sc == 404
            puts("#{R}#{'['.rjust(9, '.')} Not Found ]#{W}")
          else
            puts("#{R}#{'['.rjust(9, '.')} #{r_sc} ]#{W}")
          end
        rescue StandardError => exc
          puts("\n#{R}[-] Exception : #{C}#{exc}#{W}")
          Log.write("[crawler.robots] Exception = #{exc}")
        end
      end

      def sitemap(target_url, sm_total, data, output)
        print("#{G}[+] #{C}Looking for sitemap.xml#{W}")

        begin
          sm_rqst = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(target_url, verify: false)
          sm_sc = sm_rqst.status
          if sm_sc == 200
            puts("#{G}#{'['.rjust(8, '.')} Found ]#{W}")
            print("#{G}[+] #{C}Extracting sitemap Links#{W}")

            sm_page = sm_rqst.to_s
            sm_soup = Nokogiri::XML(sm_page)
            sm_soup.xpath('//loc').each do |node|
              url = node.text
              sm_total << url if url && !url.empty?
            end

            sm_total.uniq!
            puts("#{G}#{'['.rjust(7, '.')} #{sm_total.length} ]#{W}")
            exporter(data, output, sm_total, 'sitemap')
          elsif sm_sc == 404
            puts("#{R}#{'['.rjust(8, '.')} Not Found ]#{W}")
          else
            puts("#{R}#{'['.rjust(8, '.')} Status Code : #{sm_sc} ]#{W}")
          end
        rescue StandardError => exc
          puts("\n#{R}[-] Exception : #{C}#{exc}#{W}")
          Log.write("[crawler.sitemap] Exception = #{exc}")
        end
      end

      def css(target, css_total, data, soup, output)
        print("#{G}[+] #{C}Extracting CSS Links#{W}")
        soup.css('link[href]').each do |link|
          href = link['href']
          next unless href && href.include?('.css')

          css_total << url_filter(target, href)
        end
        css_total.compact!
        css_total.uniq!
        puts("#{G}#{'['.rjust(11, '.')} #{css_total.length} ]#{W}")
        exporter(data, output, css_total, 'css')
      end

      def js_scan(target, js_total, data, soup, output)
        print("#{G}[+] #{C}Extracting Javascript Links#{W}")
        soup.css('script[src]').each do |tag|
          src = tag['src']
          next unless src && src.include?('.js')

          tmp = url_filter(target, src)
          js_total << tmp if tmp
        end
        js_total.uniq!
        puts("#{G}#{'['.rjust(4, '.')} #{js_total.length} ]#{W}")
        exporter(data, output, js_total, 'javascripts')
      end

      def registered_domain_for(target)
        host = URI.parse(target).host
        return nil unless host

        PublicSuffix.domain(host)
      rescue StandardError
        nil
      end

      def internal_links(target, int_total, data, soup, output)
        print("#{G}[+] #{C}Extracting Internal Links#{W}")

        domain = registered_domain_for(target)
        soup.css('a[href]').each do |a|
          href = a['href']
          next unless href
          next unless domain && href.include?(domain)

          int_total << href
        end

        int_total.uniq!
        puts("#{G}#{'['.rjust(6, '.')} #{int_total.length} ]#{W}")
        exporter(data, output, int_total, 'internal_urls')
      end

      def external_links(target, ext_total, data, soup, output)
        print("#{G}[+] #{C}Extracting External Links#{W}")

        domain = registered_domain_for(target)
        soup.css('a[href]').each do |a|
          href = a['href']
          next unless href
          next unless href.include?('http')
          next if domain && href.include?(domain)

          ext_total << href
        end

        ext_total.uniq!
        puts("#{G}#{'['.rjust(6, '.')} #{ext_total.length} ]#{W}")
        exporter(data, output, ext_total, 'external_urls')
      end

      def images(target, img_total, data, soup, output)
        print("#{G}[+] #{C}Extracting Images#{W}")
        soup.css('img[src]').each do |img|
          src = img['src']
          next unless src && src.length > 1

          img_total << url_filter(target, src)
        end
        img_total.compact!
        img_total.uniq!
        puts("#{G}#{'['.rjust(14, '.')} #{img_total.length} ]#{W}")
        exporter(data, output, img_total, 'images')
      end

      def sm_crawl(data, sm_crawl_total, sm_total, sm_url, output)
        print("#{G}[+] #{C}Crawling Sitemaps#{W}")

        sm_total.each do |site_url|
          next if site_url == sm_url
          next unless site_url.end_with?('xml')

          begin
            sm_rqst = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(site_url, verify: false)
            next unless sm_rqst.status == 200

            sm_soup = Nokogiri::XML(sm_rqst.to_s)
            sm_soup.xpath('//loc').each do |node|
              url = node.text
              sm_crawl_total << url if url && !url.empty?
            end
          rescue StandardError => exc
            Log.write("[crawler.sm_crawl] Exception = #{exc}")
          end
        end

        sm_crawl_total.uniq!
        puts("#{G}#{'['.rjust(14, '.')} #{sm_crawl_total.length} ]#{W}")
        exporter(data, output, sm_crawl_total, 'urls_inside_sitemap')
      end

      def js_crawl(data, js_crawl_total, js_total, output)
        print("#{G}[+] #{C}Crawling Javascripts#{W}")

        js_total.each do |js_url|
          begin
            js_rqst = HTTPX.with(headers: USER_AGENT, timeout: { operation_timeout: 10 }).get(js_url, verify: false)
            next unless js_rqst.status == 200

            js_rqst.to_s.split(';').each do |line|
              next unless line.include?('http://') || line.include?('https://')

              line.scan(/\"(http[s]?:\/\/.*?)\"/).flatten.each do |item|
                js_crawl_total << item if item && item.length > 8
              end
            end
          rescue StandardError => exc
            Log.write("[crawler.js_crawl] Exception = #{exc}")
          end
        end

        js_crawl_total.uniq!
        puts("#{G}#{'['.rjust(11, '.')} #{js_crawl_total.length} ]#{W}")
        exporter(data, output, js_crawl_total, 'urls_inside_js')
      end

      def exporter(data, output, list_name, file_name)
        return unless output

        data["module-crawler-#{file_name}"] = { 'links' => list_name.dup, 'exported' => false }
        fname = File.join(output[:directory], "#{file_name}.#{output[:format]}")
        output[:file] = fname
        Export.call(output, data)
      end

      def stats(output, r_total, sm_total, css_total, js_total, int_total, ext_total, img_total, sm_crawl_total,
                js_crawl_total, total, data, soup)
        total.concat(r_total)
        total.concat(sm_total)
        total.concat(css_total)
        total.concat(js_total)
        total.concat(js_crawl_total)
        total.concat(sm_crawl_total)
        total.concat(int_total)
        total.concat(ext_total)
        total.concat(img_total)
        total.uniq!

        puts("\n#{G}[+] #{C}Total Unique Links Extracted : #{W}#{total.length}")

        return unless output
        return if total.empty?

        title = soup.at('title')&.text || 'None'

        data['module-crawler-stats'] = {
          'Total Unique Links Extracted' => total.length.to_s,
          'Title ' => title,
          'total_urls_robots' => r_total.length,
          'total_urls_sitemap' => sm_total.length,
          'total_urls_css' => css_total.length,
          'total_urls_js' => js_total.length,
          'total_urls_in_js' => js_crawl_total.length,
          'total_urls_in_sitemaps' => sm_crawl_total.length,
          'total_urls_internal' => int_total.length,
          'total_urls_external' => ext_total.length,
          'total_urls_images' => img_total.length,
          'total_urls' => total.length,
          'exported' => false
        }
      end
    end
  end
end
