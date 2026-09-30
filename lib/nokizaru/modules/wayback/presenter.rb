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

        def cdx_status(cdx_status, urls, health = nil)
          return row(:error, 'Fetching URLs from CDX', empty_cdx_label(cdx_status, health)) if urls.empty?

          detail = cdx_status.to_s.start_with?('partial') ? "#{urls.length} retained" : urls.length.to_s
          detail += ' (availability fallback)' if cdx_status == 'fallback'
          row(cdx_status.to_s.start_with?('partial') ? :error : :info, 'Fetching URLs from CDX', detail)
        end

        def empty_cdx_label(status, health)
          label = case status
                  when 'timeout' then 'Timeout'
                  when 'rate_limited' then 'Rate limited'
                  when 'archive_degraded' then 'Archive degraded'
                  else 'Not Found'
                  end
          reason = human_status(health&.[]('reason'))
          reason.empty? || reason == label ? label : "#{label} (#{reason})"
        end

        def archive_status(status, cdx_status = nil)
          type = status == 'degraded' ? :error : :info
          label = if cdx_status.to_s.start_with?('partial_')
                    "Partial (#{human_status(cdx_status.delete_prefix('partial_')).downcase})"
                  elsif status == 'degraded'
                    'Degraded or rate-limited'
                  else
                    status.to_s.capitalize
                  end
          row(type, 'Archive.org service status', label)
        end

        def snapshots(historical, changed)
          row(:plus, 'Historical snapshots selected', Array(historical).length)
          row(:plus, 'State-change snapshots selected', Array(changed).length)
          snapshot_list('Wayback Historical Snapshots', historical) do |snapshot|
            human_status(Array(snapshot['reasons']).first)
          end
          snapshot_list('Wayback State-Change Snapshots', changed) do |snapshot|
            changes = Array(snapshot['changes']).map { |value| human_status(value).downcase }.join(', ')
            changes.empty? ? 'Changed' : "Changed (#{changes})"
          end
        end

        def snapshot_list(title, snapshots)
          list = Array(snapshots)
          return if list.empty?

          UI.tree_header(title)
          rows = list.map { |snapshot| [yield(snapshot), snapshot['snapshot_url']] }
          UI.tree_rows(rows)
        end

        def manual_pivots(pivots)
          UI.tree_header('Wayback Manual Review Links')
          UI.tree_rows([
                         ['Calendar', pivots['calendar_url']],
                         ['Changes', pivots['changes_url']],
                         ['Availability API', pivots['availability_query_url']],
                         ['CDX API', pivots['cdx_query_url']]
                       ])
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
