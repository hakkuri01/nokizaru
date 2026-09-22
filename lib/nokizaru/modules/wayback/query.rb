# frozen_string_literal: true

require 'json'
require 'timeout'
require 'uri'

module Nokizaru
  module Modules
    module Wayback
      module Query
        module_function

        MIN_REDUCED_CDX_BUDGET = 1.0
        UNHEALTHY_SOURCE_STATUSES = %w[failed timeout].freeze
        DEGRADED_REASONS = %w[
          timeout request_failed exception service_unavailable rate_limited
        ].freeze

        def deadline_after(timeout_s) = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s.to_f

        def remaining_time(deadline_at, fallback = 0.0)
          return fallback.to_f unless deadline_at

          [deadline_at.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0].max
        end

        def bounded_timeout(timeout_s, deadline_at: nil)
          timeout = timeout_s.to_f
          timeout = [timeout, remaining_time(deadline_at)].min if deadline_at
          [timeout, 0.0].max
        end

        def source_health(status, records: 0, reason: nil, limit: nil)
          health = { 'status' => status.to_s, 'records' => records.to_i }
          health['reason'] = reason.to_s if reason
          health['limit'] = limit.to_i if limit
          health
        end

        def availability_status(target, timeout_s, deadline_at: nil)
          timeout = bounded_timeout(timeout_s, deadline_at: deadline_at)
          return { state: :unknown, snapshots: nil, reason: 'timeout' } unless timeout.positive?

          variants = availability_variants(target)
          variants.each_with_index do |variant, index|
            variant_timeout = availability_variant_timeout(timeout, index, deadline_at)
            next unless variant_timeout.positive?

            result = Timeout.timeout(variant_timeout) do
              check_availability_status(variant, timeout_s: variant_timeout, deadline_at: deadline_at)
            end
            result[:variant] = variant
            return result if result[:state] == :available || degraded_reason?(result[:reason])

            result[:attempted_variants] = variants.first(index + 1)
            return result unless remaining_time(deadline_at, timeout).positive?
          rescue Timeout::Error
            return { state: :unknown, snapshots: nil, reason: 'timeout', variant: variant }
          end

          { state: :not_available, snapshots: nil, reason: nil, attempted_variants: variants }
        rescue Timeout::Error
          { state: :unknown, snapshots: nil, reason: 'timeout' }
        end

        def check_availability_status(target, timeout_s: nil, deadline_at: nil)
          uri = URI(Wayback::AVAIL_URL)
          uri.query = URI.encode_www_form(url: target)
          timed_out = false
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, on_timeout: -> { timed_out = true })
          return { state: :unknown, snapshots: nil, reason: timed_out ? 'timeout' : 'request_failed' } unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return { state: :unknown, snapshots: nil, reason: response_reason(status) } unless status == 200

          availability_state(JSON.parse(response.body)['archived_snapshots'])
        rescue Timeout::Error
          { state: :unknown, snapshots: nil, reason: 'timeout' }
        rescue StandardError => e
          Log.write("[wayback] availability check exception = #{e}")
          { state: :unknown, snapshots: nil, reason: 'exception' }
        end

        def availability_state(snapshots)
          return { state: :not_available, snapshots: nil, reason: nil } unless snapshots&.any?

          { state: :available, snapshots: snapshots, reason: nil }
        end

        def availability_health(availability)
          case availability[:state]
          when :available
            source_health('found', records: Normalize.fallback_urls_from_availability(availability[:snapshots]).length)
          when :not_available
            source_health('empty')
          else
            status = availability[:reason] == 'timeout' ? 'timeout' : 'failed'
            source_health(status, reason: availability[:reason])
          end
        end

        def availability_variants(target)
          uri = URI.parse(target.to_s)
          host = uri.host.to_s.downcase
          return [target.to_s] if host.empty?

          path = uri.path.to_s
          path = '/' if path.empty?
          hosts = [host, alternate_www_host(host)].compact.uniq
          ([target.to_s] + hosts.flat_map do |candidate|
            ["https://#{candidate}#{path}", "http://#{candidate}#{path}"]
          end).uniq
        rescue StandardError
          [target.to_s]
        end

        def alternate_www_host(host)
          value = host.to_s.downcase
          return nil if value.empty?
          return value.delete_prefix('www.') if value.start_with?('www.')

          "www.#{value}"
        end

        def availability_variant_timeout(total_timeout, index, deadline_at)
          remaining = bounded_timeout(total_timeout, deadline_at: deadline_at)
          return 0.0 unless remaining.positive?
          return [remaining, 3.0].min if index.zero?

          [remaining, 10.0].min
        end

        def availability_timeout(total_timeout)
          timeout = total_timeout.to_f
          return 3.0 if timeout <= 0

          [timeout * 0.50, 6.0].max.clamp(3.0, 12.0)
        end

        def cdx_timeout(total_timeout, availability_timeout_s)
          timeout = total_timeout.to_f - availability_timeout_s.to_f
          timeout.positive? ? timeout : 2.0
        end

        def fetch_urls_with_status(target, timeout_s, snapshots, deadline_at: nil, availability: nil)
          availability ||= availability_state(snapshots)
          urls, status, reasons = fetch_cdx_with_fallback(target, timeout_s, snapshots, deadline_at: deadline_at)
          cdx_source = status == 'timeout_with_fallback' ? 'availability' : 'wayback'
          records = urls.map { |url| archive_record(url, cdx_source) }
          cdx_record_count = cdx_source == 'wayback' ? records.length : 0
          source_timeout = bounded_timeout([timeout_s.to_f * 0.35, 2.0].max, deadline_at: deadline_at)
          external_records, external_health = ArchiveSources.fetch_records(
            target, source_timeout, deadline_at: deadline_at
          )
          records.concat(external_records)
          health = external_health.merge(
            'availability' => availability_health(availability),
            'cdx' => cdx_health(status, reasons, cdx_record_count)
          )

          filtered_urls, filtered_records = finalize_records(target, records)
          normalized_status = normalize_cdx_status(filtered_urls, status)
          [filtered_urls, normalized_status, reasons, filtered_records, availability, health]
        end

        def cdx_health(status, reasons, records)
          reason = Array(reasons).last
          health_status = case status
                          when 'found', 'found_partial_timeout', 'found_reduced' then 'found'
                          when 'not_found' then 'empty'
                          when 'timeout', 'timeout_with_fallback' then reason == 'timeout' ? 'timeout' : 'empty'
                          else reason == 'timeout' ? 'timeout' : 'failed'
                          end
          source_health(health_status, records: health_status == 'found' ? records : 0,
                                       reason: reason || ('request_failed' if health_status == 'failed'))
        end

        def finalize_records(target, records)
          records = ArchiveSources.dedupe_records(records)
          urls = Normalize.filter_urls(records.map { |record| record['url'] }, target: target)
          records = ArchiveSources.filter_records(records, urls).first(Wayback::MAX_URLS)
          [records.map { |record| record['url'] }, records]
        end

        def build_cdx_payload(target, limit:, collapse: false, status_filter: true, pattern: nil)
          payload = {
            'url' => pattern || ArchiveSources.cdx_target_pattern(target),
            'fl' => 'original',
            'limit' => limit.to_i.to_s
          }
          payload['collapse'] = 'urlkey' if collapse
          payload['filter'] = 'statuscode:200' if status_filter
          payload
        end

        def cdx_attempt_plan
          [
            { limit: 25, timeout_share: 0.75, collapse: false, status_filter: false, pattern_index: 0 },
            { limit: 25, timeout_share: 0.25, collapse: false, status_filter: true, pattern_index: 1 }
          ]
        end

        def fetch_cdx_with_fallback(target, timeout_s, snapshots, deadline_at: nil)
          fallback = Normalize.fallback_urls_from_availability(snapshots)
          urls, timed_out, reasons = fetch_staged_cdx(
            target, timeout_s, deadline_at: deadline_at, fallback_available: fallback.any?
          )
          return [urls, timed_out ? 'found_partial_timeout' : 'found', reasons] unless urls.empty?

          if fallback.any?
            Presenter.fallback_used(fallback.length)
            return [fallback, 'timeout_with_fallback', reasons]
          end

          reduced = if remaining_time(deadline_at, timeout_s) >= MIN_REDUCED_CDX_BUDGET
                      fetch_reduced_cdx(target, timeout_s, deadline_at: deadline_at)
                    else
                      []
                    end
          return [reduced, 'found_reduced', reasons] unless reduced.empty?

          Log.write('[wayback] CDX fetch timed out, using availability fallback')
          [[], cdx_empty_status(reasons, timed_out), reasons]
        end

        def fetch_staged_cdx(target, timeout_s, deadline_at: nil, fallback_available: false)
          total_timeout = bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [[], true, ['timeout']] unless total_timeout.positive?

          aggregated = []
          seen = {}
          reasons = []
          timed_out = false
          cdx_attempt_plan.each do |attempt|
            payload = build_cdx_payload(
              target,
              limit: attempt[:limit],
              collapse: attempt[:collapse],
              status_filter: attempt[:status_filter],
              pattern: ArchiveSources.cdx_pattern(target, attempt)
            )
            attempt_timeout = bounded_timeout(
              [total_timeout * attempt[:timeout_share].to_f, 1.2].max,
              deadline_at: deadline_at
            )
            break unless attempt_timeout.positive?

            attempt_urls, attempt_timed_out, reason = fetch_urls_with_timeout(
              payload, attempt_timeout, deadline_at: deadline_at
            )
            timed_out ||= attempt_timed_out
            reasons << reason if reason
            append_unique_urls(aggregated, seen, attempt_urls)
            break if aggregated.any? || (attempt_timed_out && fallback_available)
          end

          [aggregated.first(Wayback::MAX_URLS), timed_out, reasons]
        end

        def fetch_urls_with_timeout(payload, timeout_s, deadline_at: nil)
          timeout = bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [[], true, 'timeout'] unless timeout.positive?

          urls, reason = Timeout.timeout(timeout) do
            fetch_urls_result(payload, timeout_s: timeout, deadline_at: deadline_at)
          end
          [urls, false, reason]
        rescue Timeout::Error
          [[], true, 'timeout']
        end

        def fetch_reduced_cdx(target, timeout_s, deadline_at: nil)
          payload = build_cdx_payload(target, limit: 50, collapse: false)
          timeout = bounded_timeout([timeout_s.to_f * 0.45, 2.0].max, deadline_at: deadline_at)
          return [] unless timeout.positive?

          Timeout.timeout(timeout) { fetch_urls(payload, timeout_s: timeout, deadline_at: deadline_at) }
        rescue Timeout::Error
          []
        end

        def fetch_urls(payload, timeout_s: nil, deadline_at: nil)
          urls, = fetch_urls_result(payload, timeout_s: timeout_s, deadline_at: deadline_at)
          urls
        end

        def fetch_urls_result(payload, timeout_s: nil, deadline_at: nil)
          uri = URI(Wayback::CDX_URL)
          uri.query = URI.encode_www_form(payload)
          timed_out = false
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, on_timeout: -> { timed_out = true })
          return [[], timed_out ? 'timeout' : 'request_failed'] unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return [[], response_reason(status)] unless status == 200

          [parse_cdx_lines(response.body), nil]
        rescue Timeout::Error
          [[], 'timeout']
        rescue StandardError => e
          Log.write("[wayback] CDX fetch exception = #{e}")
          [[], 'exception']
        end

        def parse_cdx_lines(body)
          seen = {}
          body.to_s.each_line.filter_map do |line|
            url = line.strip
            next if url.empty? || seen[url]

            seen[url] = true
            url
          end
        end

        def append_unique_urls(aggregated, seen, urls)
          Array(urls).each do |url|
            next if seen[url]

            seen[url] = true
            aggregated << url
          end
        end

        def archive_record(url, source, timestamp = nil)
          ArchiveSources.archive_record(url, source, timestamp)
        end

        def normalize_cdx_status(urls, status)
          return 'found' if urls.any? && status == 'not_found'
          return 'not_found' if urls.empty? && status == 'found'
          return 'timeout' if urls.empty? && status == 'timeout_with_fallback'

          status
        end

        def cdx_empty_status(reasons, timed_out)
          return 'archive_degraded' if Array(reasons).any? { |reason| degraded_reason?(reason) }
          return 'timeout' if timed_out

          'not_found'
        end

        def response_reason(code)
          case code.to_i
          when 429 then 'rate_limited'
          when 500..599 then 'service_unavailable'
          else "http_#{code}"
          end
        end

        def degraded_reason?(reason) = DEGRADED_REASONS.include?(reason.to_s)

        def archive_status(availability, cdx_status, cdx_reasons, source_health = nil)
          return 'degraded' if unhealthy_sources?(source_health)

          reasons = [availability&.[](:reason), *Array(cdx_reasons)].compact
          return 'degraded' if cdx_status == 'archive_degraded' || reasons.any? { |reason| degraded_reason?(reason) }
          return 'healthy' if availability&.[](:state) == :available || cdx_status.to_s.start_with?('found')
          return 'healthy' if availability&.[](:state) == :not_available && cdx_status == 'not_found'

          'unknown'
        end

        def unhealthy_sources?(health)
          %w[availability cdx].any? do |source|
            UNHEALTHY_SOURCE_STATUSES.include?(health&.dig(source, 'status'))
          end
        end

        def manual_pivots(target)
          target_value = target.to_s
          cdx_payload = build_cdx_payload(target_value, limit: 25, status_filter: false)
          {
            'calendar_url' => "https://web.archive.org/web/*/#{URI::DEFAULT_PARSER.escape(target_value)}",
            'availability_query_url' => "#{Wayback::AVAIL_URL}?#{URI.encode_www_form(url: target_value)}",
            'cdx_query_url' => "#{Wayback::CDX_URL}?#{URI.encode_www_form(cdx_payload)}"
          }
        end
      end
    end
  end
end
