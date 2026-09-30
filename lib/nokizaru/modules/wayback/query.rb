# frozen_string_literal: true

require 'json'
require 'timeout'
require 'uri'

module Nokizaru
  module Modules
    module Wayback
      module Query
        module_function

        MAX_CDX_RECORDS = 50_000
        MAX_CDX_RECORD_BYTES = 32 * 1024 * 1024
        ANCHOR_BUDGET_SHARE = 0.10
        MAX_AVAIL_BODY_BYTES = 1024 * 1024
        PAGE_DELAY = 0.25
        POST_PROCESSING_BUDGET = 2.0
        UNHEALTHY_SOURCE_STATUSES = %w[failed timeout rate_limited].freeze
        DEGRADED_REASONS = %w[
          timeout request_failed exception service_unavailable rate_limited invalid_response response_too_large
          record_limit byte_limit
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

        def source_health(status, records: 0, reason: nil)
          health = { 'status' => status.to_s, 'records' => records.to_i }
          health['reason'] = reason.to_s if reason
          health
        end

        def fetch_urls_with_status(target, timeout_s, deadline_at: nil)
          deadline_at ||= deadline_after(timeout_s)
          now = Time.now.utc
          anchor_history = fetch_anchor_history(target, timeout_s, deadline_at, now)
          change_history = fetch_cdx_history(target, timeout_s, deadline_at: deadline_at)
          history = combine_histories(anchor_history, change_history)
          availability, wayback_records = fallback_records(target, history, deadline_at)

          urls, records = finalize_records(wayback_records)
          health = {
            'availability' => availability_health(availability, history[:fallback_records]),
            'cdx' => cdx_health(history, history[:records].map { |record| record['url'] }.uniq.length)
          }
          status = history[:fallback] ? 'fallback' : history[:status]
          snapshots = snapshot_selection(change_history[:records], anchor_history[:records], status, now)

          [urls, status, history[:reasons], records, availability, health,
           snapshots[:historical], snapshots[:changed]]
        end

        def snapshot_selection(change_records, anchor_records, status, now)
          return { historical: [], changed: [] } if status == 'fallback'

          History.select(change_records, historical_records: anchor_records, now: now)
        end

        def fetch_anchor_history(target, timeout_s, deadline_at, now)
          results = History::ANCHORS.map do |reason, (days, tolerance)|
            budget = anchor_budget(timeout_s, deadline_at)
            break history_result([], 'timeout', ['timeout'], nil) unless budget.positive?

            fetch_anchor_window(target, reason, days, tolerance, now, budget)
          end
          combine_results(results.compact)
        end

        def anchor_budget(timeout_s, deadline_at)
          available = remaining_time(deadline_at) - POST_PROCESSING_BUDGET
          [timeout_s.to_f * ANCHOR_BUDGET_SHARE, available].min.clamp(0.0, timeout_s.to_f)
        end

        def fetch_anchor_window(target, reason, days, tolerance, now, timeout_s)
          anchor = now - (days * 86_400)
          payload = CDX.build_payload(
            target,
            collapse: 'urlkey',
            from: timestamp_value(anchor - (tolerance * 86_400)),
            to: timestamp_value(anchor + (tolerance * 86_400))
          )
          deadline_at = deadline_after(timeout_s)
          rows, resume_key, error = CDX.fetch_page(payload, timeout_s, deadline_at: deadline_at)
          return history_result([], response_failure_status(error), [error], nil) if error

          records = rows.filter_map { |row| history_record(row, target, anchor_reason: reason) }
          status = resume_key ? 'partial_limit' : 'complete'
          reasons = resume_key ? ['record_limit'] : []
          history_result(records, status, reasons, resume_key)
        end

        def timestamp_value(time) = time.utc.strftime('%Y%m%d%H%M%S')

        def fetch_cdx_history(target, timeout_s, deadline_at: nil)
          deadline_at ||= deadline_after(timeout_s)
          page_deadline = deadline_at - deadline_margin(timeout_s)
          payload = CDX.build_payload(target)
          records = []
          record_bytes = 0
          resume_key = nil
          seen_keys = {}

          loop do
            page, next_key, reason = next_history_page(payload, resume_key, page_deadline)
            return history_result(records, partial_status(reason, records), [reason], resume_key) if reason

            record_bytes, limit_reason = append_history_page(records, record_bytes, page, target)
            return history_result(records, 'partial_limit', [limit_reason], next_key) if limit_reason
            return history_result(records, 'complete', [], nil) if next_key.to_s.empty?
            return history_result(records, 'partial_failure', ['repeated_resume_key'], next_key) if seen_keys[next_key]

            seen_keys[next_key] = true
            resume_key = next_key
            wait_for_next_page(page_deadline)
          end
        end

        def append_history_page(records, record_bytes, page, target)
          page.each do |row|
            record = history_record(row, target)
            next unless record

            size = record_size(record)
            return [record_bytes, 'record_limit'] if records.length >= MAX_CDX_RECORDS
            return [record_bytes, 'byte_limit'] if record_bytes + size > MAX_CDX_RECORD_BYTES

            records << record
            record_bytes += size
          end
          [record_bytes, nil]
        end

        def record_size(record)
          record.values.sum { |value| value.to_s.bytesize }
        end

        def deadline_margin(timeout_s) = [timeout_s.to_f * 0.10, 5.0].min

        def wait_for_next_page(deadline_at)
          delay = [PAGE_DELAY, remaining_time(deadline_at)].min
          sleep(delay) if delay.positive?
        end

        def next_history_page(payload, resume_key, deadline_at)
          timeout = bounded_timeout(remaining_time(deadline_at), deadline_at: deadline_at)
          return [[], nil, 'timeout'] unless timeout.positive?

          payload['resumeKey'] = resume_key if resume_key
          CDX.fetch_page(payload, timeout, deadline_at: deadline_at)
        end

        def history_record(row, target, anchor_reason: nil)
          url = row['original']
          return nil unless Normalize.filter_urls([url], target: target, include_noise: true, exact_host: true).any?

          record = { 'url' => url.to_s, 'source' => 'wayback', 'timestamp' => row['timestamp'].to_s }
          record.merge!(
            'mimetype' => row['mimetype'],
            'statuscode' => row['statuscode'],
            'digest' => row['digest'],
            'snapshot_url' => History.replay_url(row['timestamp'], url)
          )
          record['anchor_reason'] = anchor_reason if anchor_reason
          record
        end

        def combine_histories(anchor_history, change_history)
          result = combine_results([anchor_history, change_history])
          result[:fallback_records] = []
          result
        end

        def combine_results(results)
          records = results.flat_map { |result| result[:records] }
          reasons = results.flat_map { |result| result[:reasons] }.uniq
          statuses = results.map { |result| result[:status] }
          status = combined_status(statuses, records)
          history_result(records, status, reasons, nil)
        end

        def combined_status(statuses, records)
          text = statuses.join(' ')
          return records.empty? ? 'timeout' : 'partial_timeout' if text.include?('timeout')
          if text.include?('rate_limited')
            return records.empty? ? 'rate_limited' : 'partial_rate_limited'
          end
          return 'partial_limit' if statuses.include?('partial_limit')
          return 'partial_failure' if text.include?('failure') || statuses.include?('archive_degraded')
          return 'not_found' if records.empty?

          'complete'
        end

        def history_result(records, status, reasons, resume_key)
          { records: records, status: records.empty? && status == 'complete' ? 'not_found' : status,
            reasons: reasons, resume_key: resume_key }
        end

        def partial_status(reason, records)
          return response_failure_status(reason) if records.empty?
          return 'partial_timeout' if reason == 'timeout'
          return 'partial_rate_limited' if reason == 'rate_limited'

          'partial_failure'
        end

        def response_failure_status(reason)
          return 'timeout' if reason == 'timeout'
          return 'rate_limited' if reason == 'rate_limited'

          'archive_degraded'
        end

        def fallback_records(target, history, deadline_at)
          availability = { state: :unknown, snapshots: nil, reason: 'not_requested' }
          return [availability, history[:records]] if cdx_finished?(history)

          timeout = (remaining_time(deadline_at) - POST_PROCESSING_BUDGET).clamp(0.0, 3.0)
          availability = availability_status(target, timeout, deadline_at: deadline_at)
          records = availability_records(availability, target)
          if records.any?
            history[:fallback] = true
            history[:fallback_records] = records
          end
          [availability, records]
        end

        def cdx_finished?(history)
          history[:records].any? || %w[complete not_found].include?(history[:status])
        end

        def availability_status(target, timeout_s, deadline_at: nil)
          timeout = bounded_timeout(timeout_s, deadline_at: deadline_at)
          return { state: :unknown, snapshots: nil, reason: 'timeout' } unless timeout.positive?

          check_availability_status(target, timeout_s: timeout, deadline_at: deadline_at)
        end

        def check_availability_status(target, timeout_s: nil, deadline_at: nil)
          uri = URI(Wayback::AVAIL_URL)
          uri.query = URI.encode_www_form(url: target)
          timed_out = false
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, on_timeout: -> { timed_out = true })
          return { state: :unknown, snapshots: nil, reason: timed_out ? 'timeout' : 'request_failed' } unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return { state: :unknown, snapshots: nil, reason: response_reason(status) } unless status == 200

          body_size = response.body.respond_to?(:bytesize) ? response.body.bytesize : response.body.to_s.bytesize
          return { state: :unknown, snapshots: nil, reason: 'response_too_large' } if body_size > MAX_AVAIL_BODY_BYTES

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

        def availability_records(availability, target)
          closest = availability.dig(:snapshots, 'closest')
          url = Normalize.original_url_from_archive_snapshot(closest&.[]('url').to_s)
          return [] if url.empty?
          return [] if Normalize.filter_urls([url], target: target, include_noise: true, exact_host: true).empty?

          record = { 'url' => url.to_s, 'source' => 'availability', 'timestamp' => closest['timestamp'].to_s }
          record['statuscode'] = closest['status'].to_s
          record['snapshot_url'] = closest['url'].to_s
          [record]
        end

        def availability_health(availability, records)
          return source_health('skipped', reason: 'not_requested') if availability[:reason] == 'not_requested'

          case availability[:state]
          when :available
            return source_health('found', records: records.length) if records.any?

            source_health('failed', reason: 'invalid_snapshot')
          when :not_available
            source_health('empty')
          else
            status = availability[:reason] == 'timeout' ? 'timeout' : 'failed'
            source_health(status, reason: availability[:reason])
          end
        end

        def cdx_health(history, records)
          status = history[:status]
          health_status = if status == 'complete'
                            records.positive? ? 'found' : 'empty'
                          elsif status == 'not_found'
                            'empty'
                          elsif status.include?('timeout')
                            'timeout'
                          elsif status.include?('rate_limited')
                            'rate_limited'
                          else
                            'failed'
                          end
          source_health(health_status, records: records, reason: health_reason(status, history[:reasons]))
        end

        def health_reason(status, reasons)
          return 'timeout' if status.include?('timeout')
          return 'rate_limited' if status.include?('rate_limited')

          reasons.last
        end

        def finalize_records(records)
          records = Array(records).uniq { |record| record['url'].to_s }
          [records.map { |record| record['url'] }, records]
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
          return 'degraded' if cdx_status.to_s.start_with?('partial') || cdx_status == 'archive_degraded'
          return 'degraded' if Array(cdx_reasons).any? { |reason| degraded_reason?(reason) }
          return 'healthy' if %w[complete not_found fallback].include?(cdx_status)
          return 'healthy' if availability&.[](:state) == :available

          'unknown'
        end

        def unhealthy_sources?(health)
          %w[availability cdx].any? do |source|
            UNHEALTHY_SOURCE_STATUSES.include?(health&.dig(source, 'status'))
          end
        end

        def manual_pivots(target)
          target_value = target.to_s
          payload = CDX.build_payload(target_value).merge('limit' => '50')
          {
            'calendar_url' => "https://web.archive.org/web/*/#{URI::DEFAULT_PARSER.escape(target_value)}",
            'availability_query_url' => "#{Wayback::AVAIL_URL}?#{URI.encode_www_form(url: target_value)}",
            'cdx_query_url' => "#{Wayback::CDX_URL}?#{URI.encode_www_form(payload)}",
            'changes_url' => "https://web.archive.org/web/changes/#{URI::DEFAULT_PARSER.escape(target_value)}"
          }
        rescue ArgumentError
          {}
        end
      end
    end
  end
end
