# frozen_string_literal: true

require_relative '../log'
require_relative 'wayback/http'
require_relative 'wayback/normalize'
require_relative 'wayback/cdx'
require_relative 'wayback/history'
require_relative 'wayback/presenter'
require_relative 'wayback/query'

module Nokizaru
  module Modules
    # Wayback Machine enumeration with bounded time and safe fallbacks
    module Wayback
      module_function

      AVAIL_URL = 'https://archive.org/wayback/available'
      CDX_URL = 'https://web.archive.org/cdx/search/cdx'
      TOTAL_TIMEOUT = 60
      OUTER_TIMEOUT_MARGIN = 5
      READ_TIMEOUT = 10
      SNAPSHOT_LIMIT = 50
      INTERVAL_LIMIT = 5
      SCHEMA_VERSION = 4
      RETRIES = 2
      WAYBACK_ROW_LABEL_WIDTH = [
        'Checking availability on Wayback Machine'.length,
        'Fetching URLs from CDX'.length,
        'Historical snapshots selected'.length,
        'State-change snapshots selected'.length,
        'Archive.org service status'.length,
        'Manual Wayback Review'.length
      ].max
      AVAIL_LABELS = {
        available: 'Available',
        not_available: 'Not Available',
        unknown: 'Unknown'
      }.freeze

      def call(target, ctx, timeout_s: 10.0)
        UI.module_header('WayBack Machine')
        ctx.progress&.update(:wayback, stage: 'querying archive')
        result = execute_query(target, timeout_s)
        ctx.progress&.update(:wayback, stage: 'complete', detail: "#{Array(result[:urls]).length} urls")
        persist_wayback(ctx, result)
        Log.write('[wayback] Completed')
      rescue Timeout::Error => e
        persist_wayback(ctx, failure_result(target, e, timed_out: true))
        Log.write("[wayback] Timeout = #{e}")
        raise
      rescue StandardError => e
        UI.line(:error, "Exception : #{e}")
        Log.write("[wayback] Exception = #{e}")
        persist_wayback(ctx, failure_result(target, e))
      end

      def execute_query(target, timeout_s)
        timeout_value = normalized_timeout(timeout_s)
        deadline_at = Query.deadline_after(timeout_value)
        urls, cdx_status, cdx_reasons, url_records, availability, source_health,
          historical_snapshots, changed_snapshots =
          Query.fetch_urls_with_status(target, timeout_value, deadline_at: deadline_at)
        archive_status = Query.archive_status(availability, cdx_status, cdx_reasons, source_health)
        pivots = Query.manual_pivots(target)
        Presenter.availability_status(availability[:state], source_health['availability']) unless
          source_health.dig('availability', 'reason') == 'not_requested'
        Presenter.archive_status(archive_status, cdx_status)
        Presenter.cdx_status(cdx_status, urls, source_health['cdx'])
        Presenter.snapshots(historical_snapshots, changed_snapshots)
        Presenter.manual_pivots(pivots) if urls.empty?
        {
          timed_out: cdx_status.to_s.include?('timeout') || cdx_reasons.include?('timeout'),
          availability: availability,
          archive_status: archive_status,
          cdx_status: cdx_status,
          cdx_reasons: cdx_reasons,
          source_health: source_health,
          urls: urls,
          url_records: url_records,
          historical_snapshots: historical_snapshots,
          changed_snapshots: changed_snapshots,
          manual_pivots: pivots,
          elapsed_s: timeout_value - [Query.remaining_time(deadline_at), 0.0].max
        }
      end

      def normalized_timeout(timeout_s)
        value = timeout_s.to_f
        value.positive? ? value : TOTAL_TIMEOUT
      end

      def persist_wayback(ctx, result)
        urls = Array(result[:urls])
        triage = result[:triage] || Normalize.triage(urls)
        high_signal_urls = triage['review_urls']
        persist_wayback_artifacts(ctx, urls, high_signal_urls, triage, result)
        ctx.run['modules']['wayback'] = wayback_payload(result, urls, high_signal_urls, triage)
      end

      def persist_wayback_artifacts(ctx, urls, high_signal_urls, triage, result)
        ctx.add_artifact('urls', urls) if urls.any?
        ctx.add_artifact('wayback_urls', urls) if urls.any?
        ctx.add_artifact('wayback_high_signal_urls', high_signal_urls) if high_signal_urls.any?
        snapshots = Array(result[:historical_snapshots]) + Array(result[:changed_snapshots])
        snapshot_urls = snapshots.filter_map { |snapshot| snapshot['snapshot_url'] }
        ctx.add_artifact('wayback_snapshot_urls', snapshot_urls) if snapshot_urls.any?
        triage.each do |category, values|
          next unless category.end_with?('_urls') && values.any?

          ctx.add_artifact("wayback_#{category}", values)
        end
      end

      def wayback_payload(result, urls, high_signal_urls, triage)
        payload = {
          'schema_version' => SCHEMA_VERSION,
          'status' => result[:status] || 'complete',
          'error' => result[:error],
          'timed_out' => result[:timed_out] == true,
          'archive_status' => result[:archive_status],
          'cdx_status' => result[:cdx_status],
          'cdx_reasons' => Array(result[:cdx_reasons]),
          'source_health' => result[:source_health] || {},
          'urls' => urls,
          'url_records' => Array(result[:url_records]),
          'historical_snapshots' => Array(result[:historical_snapshots]),
          'changed_snapshots' => Array(result[:changed_snapshots]),
          'high_signal_urls' => high_signal_urls,
          'manual_pivots' => result[:manual_pivots],
          'elapsed_s' => result[:elapsed_s].to_f.round(4)
        }
        payload.merge!(availability_payload(result[:availability]))
        payload.merge!(triage)
        payload
      end

      def availability_payload(availability)
        availability ||= {}
        {
          'availability' => availability[:state].to_s,
          'availability_reason' => availability[:reason]
        }
      end

      def failure_result(target, error, timed_out: false)
        reason = timed_out ? 'timeout' : 'exception'
        health = {
          'cdx' => Query.source_health('failed', reason: reason),
          'availability' => Query.source_health('skipped', reason: reason)
        }
        {
          status: 'failed', error: "#{error.class}: #{error.message}", timed_out: timed_out,
          availability: { state: :unknown, reason: reason }, archive_status: 'degraded',
          cdx_status: timed_out ? 'timeout' : 'archive_degraded', cdx_reasons: [reason], source_health: health,
          manual_pivots: Query.manual_pivots(target)
        }
      end
    end
  end
end
