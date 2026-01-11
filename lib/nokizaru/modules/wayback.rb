# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'timeout'
require_relative '../log'

module Nokizaru
  module Modules
    module Wayback
      module_function

      R = "\e[31m"
      G = "\e[32m"
      C = "\e[36m"
      W = "\e[0m"
      Y = "\e[33m"

      AVAIL_URL = 'http://archive.org/wayback/available'
      CDX_URL   = 'http://web.archive.org/cdx/search/cdx'

      # Hard timeout for entire operation
      TOTAL_TIMEOUT = 10

      # Socket-level timeouts
      CONNECT_TIMEOUT = 5
      READ_TIMEOUT = 10

      # Max URLs to fetch (prevents downloading 500k+ URLs)
      MAX_URLS = 5000

      def call(target, ctx, timeout_s: 10.0)
        puts("\n#{Y}[!] Starting WayBack Machine...#{W}\n")

        domain_query = "#{target}/*"
        curr_yr = Date.today.year
        last_yr = curr_yr - 5

        # Check availability with timeout
        print("#{Y}[!] #{C}Checking Availability on Wayback Machine#{W}")
        $stdout.flush

        avail_data = with_timeout(TOTAL_TIMEOUT) { check_availability(target) }

        if avail_data
          puts("#{G}#{'['.rjust(5, '.')} Available ]#{W}")
        else
          puts("#{R}#{'['.rjust(5, '.')} N/A ]#{W}")
          ctx.run['modules']['wayback'] = { 'urls' => [] }
          Log.write('[wayback] Completed')
          return
        end

        # Fetch URLs with timeout
        print("#{Y}[!] #{C}Fetching URLs#{W}")
        $stdout.flush

        payload = {
          'url' => domain_query,
          'fl' => 'original',
          'fastLatest' => 'true',
          'collapse' => 'urlkey',      # Deduplicate similar URLs
          'limit' => MAX_URLS.to_s,    # Cap results
          'from' => last_yr.to_s,
          'to' => curr_yr.to_s
        }

        urls = with_timeout(TOTAL_TIMEOUT) { fetch_urls(payload) }

        if urls && !urls.empty?
          puts("#{G}#{'['.rjust(5, '.')} #{urls.length} ]#{W}")
          ctx.run['modules']['wayback'] = { 'urls' => urls }
          ctx.add_artifact('urls', urls)
          ctx.add_artifact('wayback_urls', urls)
        else
          puts("#{R}#{'['.rjust(5, '.')} Not Found ]#{W}")
          ctx.run['modules']['wayback'] = { 'urls' => [] }
        end

        Log.write('[wayback] Completed')
      rescue Timeout::Error
        puts("#{R}#{'['.rjust(5, '.')} Timeout ]#{W}")
        Log.write('[wayback] Operation timed out')
        ctx.run['modules']['wayback'] = { 'urls' => [], 'error' => 'timeout' }
      rescue StandardError => e
        puts("\n#{R}[-] Exception : #{C}#{e}#{W}")
        Log.write("[wayback] Exception = #{e}")
        ctx.run['modules']['wayback'] = { 'urls' => [] }
      end

      # Execute block with hard total timeout
      def with_timeout(seconds, &block)
        Timeout.timeout(seconds, &block)
      end

      def check_availability(target)
        uri = URI(AVAIL_URL)
        uri.query = URI.encode_www_form(url: target)

        response = http_get(uri)
        return nil unless response&.code == '200'

        json = JSON.parse(response.body)
        snapshots = json['archived_snapshots']

        snapshots&.any? ? snapshots : nil
      rescue StandardError => e
        Log.write("[wayback] availability check exception = #{e}")
        nil
      end

      def fetch_urls(payload)
        uri = URI(CDX_URL)
        uri.query = URI.encode_www_form(payload)

        response = http_get(uri)
        return [] unless response&.code == '200'

        data = response.body.to_s
        urls = data.split("\n")
        urls.reject!(&:empty?)
        urls.uniq!

        urls
      rescue StandardError => e
        Log.write("[wayback] CDX fetch exception = #{e}")
        []
      end

      def http_get(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = CONNECT_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.use_ssl = (uri.scheme == 'https')

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Nokizaru'

        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Log.write("[wayback] Timeout: #{e.message}")
        nil
      rescue StandardError => e
        Log.write("[wayback] HTTP error: #{e.message}")
        nil
      end
    end
  end
end
