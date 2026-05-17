# frozen_string_literal: true

require_relative '../log'
require_relative 'wayback/archive_sources'
require_relative 'wayback/http'
require_relative 'wayback/normalize'
require_relative 'wayback/presenter'
require_relative 'wayback/query'

module Nokizaru
  module Modules
    # Wayback Machine enumeration with bounded time and safe fallbacks
    module Wayback
      module_function

      AVAIL_URL = 'https://archive.org/wayback/available'
      CDX_URL = 'https://web.archive.org/cdx/search/cdx'
      TOTAL_TIMEOUT = 10
      CONNECT_TIMEOUT = 5
      READ_TIMEOUT = 10
      MAX_URLS = 5000
      RETRIES = 2
      PREVIEW_LIMIT = 10
      WAYBACK_ROW_LABEL_WIDTH = [
        'Checking availability on Wayback Machine'.length,
        'Fetching URLs from CDX'.length,
        'Using availability snapshot fallback'.length,
        'Archive.org service status'.length,
        'Manual Wayback Review'.length
      ].max
      AVAIL_LABELS = {
        available: 'Available',
        not_available: 'Not Available',
        unknown: 'Unknown'
      }.freeze

      def call(target, ctx, timeout_s: 10.0)
        UI.module_header('Starting WayBack Machine...')
        result = execute_query(target, timeout_s)
        persist_wayback(ctx, result)
        Log.write('[wayback] Completed')
      rescue StandardError => e
        UI.line(:error, "Exception : #{e}")
        Log.write("[wayback] Exception = #{e}")
        ctx.run['modules']['wayback'] = { 'urls' => [] }
      end

      def execute_query(target, timeout_s)
        timeout_value = normalized_timeout(timeout_s)
        deadline_at = Query.deadline_after(timeout_value)
        availability_timeout_s = Query.availability_timeout(timeout_value)
        availability = Query.availability_status(target, availability_timeout_s, deadline_at: deadline_at)
        Presenter.availability_status(availability[:state])
        urls, cdx_status, cdx_reasons, url_records = Query.fetch_urls_with_status(
          target,
          Query.cdx_timeout(timeout_value, availability_timeout_s),
          availability[:snapshots],
          deadline_at: deadline_at
        )
        archive_status = Query.archive_status(availability, cdx_status, cdx_reasons)
        pivots = Query.manual_pivots(target)
        Presenter.archive_status(archive_status)
        Presenter.cdx_status(cdx_status, urls)
        Presenter.manual_pivots(pivots, archive_status: archive_status) if urls.empty?
        {
          availability: availability,
          archive_status: archive_status,
          cdx_status: cdx_status,
          cdx_reasons: cdx_reasons,
          urls: urls,
          url_records: url_records,
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
        high_signal_urls = Normalize.rank_high_signal_urls(urls)
        high_signal_urls = Array(urls).first(20) if high_signal_urls.empty? && Array(urls).any?
        Presenter.urls_preview(urls)
        ctx.add_artifact('urls', urls) if urls.any?
        ctx.add_artifact('wayback_urls', urls) if urls.any?
        ctx.add_artifact('wayback_high_signal_urls', high_signal_urls) if high_signal_urls.any?
        ctx.run['modules']['wayback'] = wayback_payload(result, urls, high_signal_urls)
      end

      def wayback_payload(result, urls, high_signal_urls)
        {
          'availability' => result.dig(:availability, :state).to_s,
          'availability_reason' => result.dig(:availability, :reason),
          'availability_variant' => result.dig(:availability, :variant),
          'archive_status' => result[:archive_status],
          'cdx_status' => result[:cdx_status],
          'cdx_reasons' => Array(result[:cdx_reasons]),
          'urls' => urls,
          'url_records' => Array(result[:url_records]),
          'high_signal_urls' => high_signal_urls,
          'manual_pivots' => result[:manual_pivots],
          'elapsed_s' => result[:elapsed_s].to_f.round(4)
        }
      end
    end
  end
end
