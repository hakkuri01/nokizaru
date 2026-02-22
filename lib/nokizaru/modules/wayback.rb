# frozen_string_literal: true

require_relative '../log'
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
        'Checking Availability on Wayback Machine'.length,
        'Fetching URLs from CDX'.length,
        'Using availability snapshot fallback'.length
      ].max
      AVAIL_LABELS = {
        available: 'Available',
        not_available: 'Not Available',
        unknown: 'Unknown'
      }.freeze

      def call(target, ctx, timeout_s: 10.0, raw: false)
        UI.module_header('Starting WayBack Machine...')
        state, cdx_status, urls = execute_query(target, timeout_s, raw)
        persist_wayback(ctx, state, cdx_status, urls)
        Log.write('[wayback] Completed')
      rescue StandardError => e
        UI.line(:error, "Exception : #{e}")
        Log.write("[wayback] Exception = #{e}")
        ctx.run['modules']['wayback'] = { 'urls' => [] }
      end

      def execute_query(target, timeout_s, raw)
        timeout_value = normalized_timeout(timeout_s)
        availability = Query.availability_status(target, timeout_value)
        Presenter.availability_status(availability[:state])
        urls, cdx_status = Query.fetch_urls_with_status(target, timeout_value, availability[:snapshots], raw: raw)
        Presenter.cdx_status(cdx_status, urls)
        [availability[:state], cdx_status, urls]
      end

      def normalized_timeout(timeout_s)
        value = timeout_s.to_f
        value.positive? ? value : TOTAL_TIMEOUT
      end

      def persist_wayback(ctx, availability_state, cdx_status, urls)
        Presenter.urls_preview(urls)
        ctx.add_artifact('urls', urls) if urls.any?
        ctx.add_artifact('wayback_urls', urls) if urls.any?
        ctx.run['modules']['wayback'] = {
          'availability' => availability_state.to_s,
          'cdx_status' => cdx_status,
          'urls' => urls
        }
      end
    end
  end
end
