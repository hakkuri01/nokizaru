# frozen_string_literal: true

module Nokizaru
  module Modules
    module Wayback
      # Terminal output helpers for Wayback module
      module Presenter
        module_function

        def availability_status(state, health = nil)
          timed_out = health&.[]('status') == 'timeout' || health&.[]('reason') == 'timeout'
          label = timed_out ? 'Timeout' : Wayback::AVAIL_LABELS.fetch(state, Wayback::AVAIL_LABELS[:unknown])
          reason = human_status(health&.[]('reason'))
          label += " (#{reason})" unless reason.empty? || reason == label
          row(state == :available ? :plus : :error, 'Checking availability on Wayback Machine', label)
        end

        def source_health(health)
          {
            'common_crawl' => 'Common Crawl source',
            'virustotal' => 'VirusTotal source'
          }.each do |source, label|
            value = health.fetch(source, {})
            detail = human_status(value['status'])
            reason = human_status(value['reason'])
            detail += " (#{reason})" unless reason.empty?
            row(value['status'] == 'failed' ? :error : :info, label, detail)
          end
        end

        def cdx_status(cdx_status, urls, health = nil)
          return row(:error, 'Fetching URLs from CDX', empty_cdx_label(cdx_status, health)) if urls.empty?

          if cdx_status == 'archive_degraded'
            detail = "#{urls.length} fallback"
            reason = human_status(health&.[]('reason'))
            detail += " (#{reason})" unless reason.empty?
            return row(:error, 'Fetching URLs from CDX', detail)
          end

          if cdx_status == 'timeout_with_fallback'
            return row(:plus, 'Fetching URLs from CDX', "#{urls.length} (availability fallback)")
          end
          return row(:plus, 'Fetching URLs from CDX', "#{urls.length} (reduced query)") if cdx_status == 'found_reduced'

          if cdx_status == 'found_partial_timeout'
            return row(:plus, 'Fetching URLs from CDX',
                       "#{urls.length} (partial, timeout)")
          end

          row(:info, 'Fetching URLs from CDX', urls.length) unless cdx_status == 'timeout_with_fallback'
        end

        def empty_cdx_label(status, health)
          label = case status
                  when 'timeout' then 'Timeout'
                  when 'archive_degraded' then 'Archive degraded'
                  else 'Not Found'
                  end
          reason = human_status(health&.[]('reason'))
          reason.empty? || reason == label ? label : "#{label} (#{reason})"
        end

        def fallback_used(count)
          row(:plus, 'Using availability snapshot fallback', count)
        end

        def archive_status(status)
          type = status == 'degraded' ? :error : :info
          label = status == 'degraded' ? 'Degraded or rate-limited' : status.to_s.capitalize
          row(type, 'Archive.org service status', label)
        end

        def manual_pivots(pivots, **)
          UI.tree_header('Wayback Manual Review Links')
          UI.tree_rows([
                         ['Calendar', pivots['calendar_url']],
                         ['Availability API', pivots['availability_query_url']],
                         ['CDX API', pivots['cdx_query_url']]
                       ])
        end

        def triage(categories)
          counts = %w[
            review_urls javascript_urls api_urls interesting_path_urls interesting_parameter_urls sensitive_file_urls
          ].map do |category|
            [category.delete_suffix('_urls').tr('_', ' ').capitalize, Array(categories[category]).length]
          end
          UI.tree_header('Wayback Triage Counts')
          UI.tree_rows(counts)
          urls_preview(categories['review_urls'])
        end

        def urls_preview(urls)
          list = Array(urls).compact
          return if list.empty?

          UI.tree_header('Wayback Review Preview')
          rows = list.first(Wayback::PREVIEW_LIMIT).map { |url| ['URL', url] }
          UI.tree_rows(rows)
          remaining = list.length - Wayback::PREVIEW_LIMIT
          UI.tree_rows([['More', remaining]]) if remaining.positive?
        end

        def row(type, label, value)
          UI.row(type, label, value, label_width: Wayback::WAYBACK_ROW_LABEL_WIDTH)
        end

        def human_status(value)
          text = value.to_s.tr('_', ' ')
          return text if text.empty?

          text = text.sub(/\A./, &:upcase)
          text.gsub(/\bapi\b/i, 'API').gsub(/\bcdx\b/i, 'CDX').gsub(/\bhttp\b/i, 'HTTP')
        end
      end
    end
  end
end
