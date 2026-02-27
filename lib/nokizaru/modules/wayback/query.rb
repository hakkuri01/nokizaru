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
          urls, status = fetch_cdx_with_fallback(target, timeout_s, snapshots)
          urls = raw ? Array(urls) : Normalize.filter_urls(urls, target: target)
          [urls, normalize_cdx_status(urls, status)]
        end

        def availability_timeout(total_timeout)
          timeout = total_timeout.to_f
          return 3.0 if timeout <= 0

          [timeout * 0.35, 1.5].max.clamp(1.5, 4.0)
        end

        def cdx_timeout(total_timeout, availability_timeout_s)
          timeout = total_timeout.to_f - availability_timeout_s.to_f
          timeout.positive? ? timeout : 2.0
        end

        def build_cdx_payload(target, from_year:, to_year:, limit:)
          {
            'url' => "#{target}/*",
            'fl' => 'original',
            'fastLatest' => 'true',
            'collapse' => 'urlkey',
            'limit' => limit.to_i.to_s,
            'from' => from_year.to_i.to_s,
            'to' => to_year.to_i.to_s
          }
        end

        def cdx_attempt_plan
          current_year = Date.today.year
          [
            { from: current_year - 2, to: current_year, limit: 900, timeout_share: 0.45 },
            { from: current_year - 5, to: current_year, limit: Wayback::MAX_URLS, timeout_share: 0.55 }
          ]
        end

        def fetch_cdx_with_fallback(target, timeout_s, snapshots)
          urls, timed_out = fetch_staged_cdx(target, timeout_s)
          return [urls, timed_out ? 'found_partial_timeout' : 'found'] unless urls.empty?

          reduced = fetch_reduced_cdx(target, timeout_s)
          return [reduced, 'found_reduced'] unless reduced.empty?

          Log.write('[wayback] CDX fetch timed out, using availability fallback')
          fallback = Normalize.fallback_urls_from_availability(snapshots)
          return [[], 'timeout'] if fallback.empty?

          Presenter.fallback_used(fallback.length)
          [fallback, 'timeout_with_fallback']
        end

        def fetch_staged_cdx(target, timeout_s)
          total_timeout = timeout_s.to_f
          return [[], true] if total_timeout <= 0

          aggregated = []
          timed_out = false

          cdx_attempt_plan.each do |attempt|
            payload = build_cdx_payload(
              target,
              from_year: attempt[:from],
              to_year: attempt[:to],
              limit: attempt[:limit]
            )
            attempt_timeout = [total_timeout * attempt[:timeout_share].to_f, 1.2].max
            attempt_urls, attempt_timed_out = fetch_urls_with_timeout(payload, attempt_timeout)
            timed_out ||= attempt_timed_out
            aggregated.concat(attempt_urls)
            aggregated.uniq!
            break if aggregated.length >= 350
          end

          [aggregated.first(Wayback::MAX_URLS), timed_out]
        end

        def fetch_urls_with_timeout(payload, timeout_s)
          urls = Timeout.timeout(timeout_s) { fetch_urls(payload) }
          [urls, false]
        rescue Timeout::Error
          [[], true]
        end

        def fetch_reduced_cdx(target, timeout_s)
          current_year = Date.today.year
          reduced_payload = build_cdx_payload(
            target,
            from_year: current_year - 2,
            to_year: current_year,
            limit: 450
          )
          reduced_timeout = [timeout_s.to_f * 0.45, 2.0].max
          Timeout.timeout(reduced_timeout) { fetch_urls(reduced_payload) }
        rescue Timeout::Error
          []
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
