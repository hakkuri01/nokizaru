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
      WAYBACK_ROW_LABEL_WIDTH = [
        'Checking Availability on Wayback Machine'.length,
        'Fetching URLs from CDX'.length,
        'Using availability snapshot fallback'.length
      ].max
      AVAIL_LABELS = {
        available: 'Available',
        not_available: 'Not Available',
        unknown: 'Unknown'
      }.freeze

      # Run this module and store normalized results in the run context
      def call(target, ctx, timeout_s: 10.0, raw: false)
        UI.module_header('Starting WayBack Machine...')

        domain_query = "#{target}/*"
        curr_yr = Date.today.year
        last_yr = curr_yr - 5
        timeout_s = timeout_s.to_f.positive? ? timeout_s.to_f : TOTAL_TIMEOUT

        availability = availability_status(target, timeout_s)
        print_availability_status(availability[:state])

        UI.line(:plus, 'Proceeding with CDX search (best effort)') if availability[:state] != :available

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
          cdx_label = cdx_status == 'timeout' ? 'Timeout' : 'Not Found'
          wayback_row(:error, 'Fetching URLs from CDX', cdx_label)
        else
          if cdx_status == 'timeout_with_fallback'
            wayback_row(:error, 'Fetching URLs from CDX', 'Timeout')
          else
            wayback_row(:info, 'Fetching URLs from CDX', urls.length)
          end
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
        UI.line(:error, "Exception : #{e}")
        Log.write("[wayback] Exception = #{e}")
        ctx.run['modules']['wayback'] = { 'urls' => [] }
      end

      # Execute block with hard total timeout
      def with_timeout(seconds, &block)
        Timeout.timeout(seconds, &block)
      end

      # Fetch Wayback availability metadata for the target URL
      def availability_status(target, timeout_s)
        with_timeout(timeout_s) { check_availability_status(target) }
      rescue Timeout::Error
        { state: :unknown, snapshots: nil, reason: 'timeout' }
      end

      # Fetch CDX results and fall back when primary query returns nothing
      def fetch_cdx_with_fallback(payload, timeout_s, snapshots)
        urls = with_timeout(timeout_s) { fetch_urls(payload) }
        [urls, 'found']
      rescue Timeout::Error
        Log.write('[wayback] CDX fetch timed out, using availability fallback')

        fallback = fallback_urls_from_availability(snapshots)
        unless fallback.empty?
          wayback_row(:plus, 'Using availability snapshot fallback', fallback.length)
          return [fallback, 'timeout_with_fallback']
        end

        [[], 'timeout']
      end

      # Check archive availability state before applying fallback logic
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

      # Fetch candidate archive URLs from Wayback endpoints
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

      # Fetch Wayback endpoints with retry and timeout controls
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

      # Decide whether an HTTP status should trigger a retry attempt
      def retryable_status?(status)
        status == 429 || status >= 500
      end

      # Print a short URL preview so large sets stay readable
      def print_urls_preview(urls)
        urls = Array(urls).compact
        return if urls.empty?

        UI.line(:info, 'Wayback URL Preview')
        urls.first(PREVIEW_LIMIT).each { |url| puts("    #{url}") }
        remaining = urls.length - PREVIEW_LIMIT
        puts("    ... #{remaining} more") if remaining.positive?
      end

      # Build fallback URLs from availability metadata when CDX is sparse
      def fallback_urls_from_availability(avail_data)
        return [] unless avail_data.is_a?(Hash)

        closest = avail_data['closest']
        return [] unless closest.is_a?(Hash)

        url = closest['url'].to_s.strip
        url.empty? ? [] : [url]
      end

      # Filter Wayback URLs to reduce low value and duplicate noise
      def filter_urls(urls)
        Array(urls)
          .map { |u| sanitize_url(u) }
          .reject(&:empty?)
          .uniq
      end

      # Normalize URL values before deduplication and output
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

      # Print Wayback availability status with useful context
      def print_availability_status(state)
        label = AVAIL_LABELS.fetch(state, AVAIL_LABELS[:unknown])
        if state == :available
          wayback_row(:plus, 'Checking Availability on Wayback Machine', label)
        elsif state == :not_available
          wayback_row(:error, 'Checking Availability on Wayback Machine', label)
        else
          wayback_row(:error, 'Checking Availability on Wayback Machine', label)
        end
      end

      # Print aligned wayback rows using one shared group width
      def wayback_row(type, label, value)
        UI.row(type, label, value, label_width: WAYBACK_ROW_LABEL_WIDTH)
      end
    end
  end
end
