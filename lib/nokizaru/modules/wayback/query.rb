# frozen_string_literal: true

require 'json'
require 'date'
require 'timeout'

module Nokizaru
  module Modules
    module Wayback
      # Query orchestration helpers for Wayback APIs
      module Query
        module_function

        def availability_status(target, timeout_s)
          Timeout.timeout(timeout_s) { check_availability_status(target) }
        rescue Timeout::Error
          { state: :unknown, snapshots: nil, reason: 'timeout' }
        end

        def check_availability_status(target)
          uri = URI(Wayback::AVAIL_URL)
          uri.query = URI.encode_www_form(url: target)
          response = HTTP.get(uri)
          return { state: :unknown, snapshots: nil, reason: 'request_failed' } unless response&.code == '200'

          availability_state(JSON.parse(response.body)['archived_snapshots'])
        rescue StandardError => e
          Log.write("[wayback] availability check exception = #{e}")
          { state: :unknown, snapshots: nil, reason: 'exception' }
        end

        def availability_state(snapshots)
          return { state: :not_available, snapshots: nil, reason: nil } unless snapshots&.any?

          { state: :available, snapshots: snapshots, reason: nil }
        end

        def fetch_urls_with_status(target, timeout_s, snapshots, raw: false)
          payload = build_cdx_payload(target)
          urls, status = fetch_cdx_with_fallback(payload, timeout_s, snapshots)
          urls = raw ? Array(urls) : Normalize.filter_urls(urls)
          [urls, normalize_cdx_status(urls, status)]
        end

        def build_cdx_payload(target)
          current_year = Date.today.year
          {
            'url' => "#{target}/*",
            'fl' => 'original',
            'fastLatest' => 'true',
            'collapse' => 'urlkey',
            'limit' => Wayback::MAX_URLS.to_s,
            'from' => (current_year - 5).to_s,
            'to' => current_year.to_s
          }
        end

        def fetch_cdx_with_fallback(payload, timeout_s, snapshots)
          urls = Timeout.timeout(timeout_s) { fetch_urls(payload) }
          [urls, 'found']
        rescue Timeout::Error
          Log.write('[wayback] CDX fetch timed out, using availability fallback')
          fallback = Normalize.fallback_urls_from_availability(snapshots)
          return [[], 'timeout'] if fallback.empty?

          Presenter.fallback_used(fallback.length)
          [fallback, 'timeout_with_fallback']
        end

        def fetch_urls(payload)
          uri = URI(Wayback::CDX_URL)
          uri.query = URI.encode_www_form(payload)
          response = HTTP.get(uri)
          return [] unless response&.code == '200'

          response.body.to_s.each_line.map(&:strip).reject(&:empty?).uniq
        rescue StandardError => e
          Log.write("[wayback] CDX fetch exception = #{e}")
          []
        end

        def normalize_cdx_status(urls, status)
          return 'not_found' if urls.empty? && status == 'found'
          return 'timeout' if urls.empty? && status == 'timeout_with_fallback'

          status
        end
      end
    end
  end
end
