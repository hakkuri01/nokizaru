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

      AVAIL_URL = 'https://archive.org/wayback/available'
      CDX_URL   = 'https://web.archive.org/cdx/search/cdx'

      # Hard timeout for entire operation
      TOTAL_TIMEOUT = 10

      # Socket-level timeouts
      CONNECT_TIMEOUT = 5
      READ_TIMEOUT = 10

      # Max URLs to fetch (prevents downloading 500k+ URLs)
      MAX_URLS = 5000
      RETRIES = 2
      PREVIEW_LIMIT = 10
      AVAIL_LABELS = {
        available: 'Available',
        not_available: 'Not Available',
        unknown: 'Unknown'
      }.freeze

      def call(target, ctx, timeout_s: 10.0, raw: false)
        puts("\n#{Y}[!] Starting WayBack Machine...#{W}\n")

        domain_query = "#{target}/*"
        curr_yr = Date.today.year
        last_yr = curr_yr - 5
        timeout_s = timeout_s.to_f.positive? ? timeout_s.to_f : TOTAL_TIMEOUT

        print("#{Y}[!] #{C}Checking Availability on Wayback Machine#{W}")
        $stdout.flush
        availability = availability_status(target, timeout_s)
        print_availability_status(availability[:state])

        puts("#{Y}[!] #{C}Proceeding with CDX search (best effort)#{W}") if availability[:state] != :available

        print("#{Y}[!] #{C}Fetching URLs from CDX#{W}")
        $stdout.flush

        payload = {
          'url' => domain_query,
          'fl' => 'original',
          'fastLatest' => 'true',
          'collapse' => 'urlkey',
          'limit' => MAX_URLS.to_s,
          'from' => last_yr.to_s,
          'to' => curr_yr.to_s
        }

        urls, cdx_status = fetch_cdx_with_fallback(payload, timeout_s, availability[:snapshots])
        urls = raw ? Array(urls) : filter_urls(urls)
        cdx_status = 'not_found' if urls.empty? && cdx_status == 'found'
        cdx_status = 'timeout' if urls.empty? && cdx_status == 'timeout_with_fallback'

        if urls.empty?
          puts("#{R}#{'['.rjust(5, '.')} Not Found ]#{W}")
        else
          puts("#{G}#{'['.rjust(5, '.')} #{urls.length} ]#{W}") unless cdx_status == 'timeout_with_fallback'
          print_urls_preview(urls)
          ctx.add_artifact('urls', urls)
          ctx.add_artifact('wayback_urls', urls)
        end

        ctx.run['modules']['wayback'] = {
          'availability' => availability[:state].to_s,
          'cdx_status' => cdx_status,
          'urls' => urls
        }

        Log.write('[wayback] Completed')
      rescue StandardError => e
        puts("\n#{R}[-] Exception : #{C}#{e}#{W}")
        Log.write("[wayback] Exception = #{e}")
        ctx.run['modules']['wayback'] = { 'urls' => [] }
      end

      # Execute block with hard total timeout
      def with_timeout(seconds, &block)
        Timeout.timeout(seconds, &block)
      end

      def availability_status(target, timeout_s)
        with_timeout(timeout_s) { check_availability_status(target) }
      rescue Timeout::Error
        { state: :unknown, snapshots: nil, reason: 'timeout' }
      end

      def fetch_cdx_with_fallback(payload, timeout_s, snapshots)
        urls = with_timeout(timeout_s) { fetch_urls(payload) }
        [urls, 'found']
      rescue Timeout::Error
        puts("#{R}#{'['.rjust(5, '.')} Timeout ]#{W}")
        Log.write('[wayback] CDX fetch timed out, using availability fallback')

        fallback = fallback_urls_from_availability(snapshots)
        unless fallback.empty?
          puts("#{Y}[!] #{C}Using availability snapshot fallback#{W}#{G}#{'['.rjust(5, '.')} #{fallback.length} ]#{W}")
          return [fallback, 'timeout_with_fallback']
        end

        [[], 'timeout']
      end

      def check_availability_status(target)
        uri = URI(AVAIL_URL)
        uri.query = URI.encode_www_form(url: target)

        response = http_get(uri)
        return { state: :unknown, snapshots: nil, reason: 'request_failed' } unless response&.code == '200'

        json = JSON.parse(response.body)
        snapshots = json['archived_snapshots']

        if snapshots&.any?
          { state: :available, snapshots: snapshots, reason: nil }
        else
          { state: :not_available, snapshots: nil, reason: nil }
        end
      rescue StandardError => e
        Log.write("[wayback] availability check exception = #{e}")
        { state: :unknown, snapshots: nil, reason: 'exception' }
      end

      def fetch_urls(payload)
        uri = URI(CDX_URL)
        uri.query = URI.encode_www_form(payload)

        response = http_get(uri)
        return [] unless response&.code == '200'

        data = response.body.to_s
        urls = data.each_line.map(&:strip)
        urls.reject!(&:empty?)
        urls.uniq!

        urls
      rescue StandardError => e
        Log.write("[wayback] CDX fetch exception = #{e}")
        []
      end

      def http_get(uri)
        attempts = 0

        while attempts <= RETRIES
          attempts += 1

          begin
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = CONNECT_TIMEOUT
            http.read_timeout = READ_TIMEOUT
            http.use_ssl = (uri.scheme == 'https')

            request = Net::HTTP::Get.new(uri)
            request['User-Agent'] = 'Nokizaru'

            response = http.request(request)
            return response unless retryable_status?(response.code.to_i) && attempts <= RETRIES
          rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                 Errno::ECONNREFUSED, SocketError => e
            if attempts > RETRIES
              Log.write("[wayback] Timeout/network error: #{e.message}")
              return nil
            end
          rescue StandardError => e
            Log.write("[wayback] HTTP error: #{e.message}")
            return nil
          end

          sleep(0.2 * attempts)
        end

        nil
      end

      def retryable_status?(status)
        status == 429 || status >= 500
      end

      def print_urls_preview(urls)
        urls = Array(urls).compact
        return if urls.empty?

        puts("#{G}[+] #{C}Wayback URL Preview#{W}")
        urls.first(PREVIEW_LIMIT).each { |url| puts("    #{W}#{url}") }
        remaining = urls.length - PREVIEW_LIMIT
        puts("    #{Y}... #{remaining} more#{W}") if remaining.positive?
      end

      def fallback_urls_from_availability(avail_data)
        return [] unless avail_data.is_a?(Hash)

        closest = avail_data['closest']
        return [] unless closest.is_a?(Hash)

        url = closest['url'].to_s.strip
        url.empty? ? [] : [url]
      end

      def filter_urls(urls)
        Array(urls)
          .map { |u| sanitize_url(u) }
          .reject(&:empty?)
          .uniq
      end

      def sanitize_url(url)
        cleaned = url.to_s.strip
        cleaned = cleaned.sub(/["'`,;\])]+\z/, '')
        return '' if cleaned.empty?

        begin
          uri = URI.parse(cleaned)
          return '' unless uri.is_a?(URI::HTTP) && uri.host
        rescue StandardError
          return ''
        end

        return '' if cleaned.include?(' ')
        return '' if cleaned.match?(/%[0-9A-Fa-f]?\z/)

        cleaned
      end

      def print_availability_status(state)
        label = AVAIL_LABELS.fetch(state, AVAIL_LABELS[:unknown])
        color = if state == :available
                  G
                else
                  (state == :not_available ? Y : R)
                end
        puts("#{color}#{'['.rjust(5, '.')} #{label} ]#{W}")
      end
    end
  end
end
