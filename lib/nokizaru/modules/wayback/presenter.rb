# frozen_string_literal: true

module Nokizaru
  module Modules
    module Wayback
      # Terminal output helpers for Wayback module
      module Presenter
        module_function

        def availability_status(state)
          label = Wayback::AVAIL_LABELS.fetch(state, Wayback::AVAIL_LABELS[:unknown])
          row(state == :available ? :plus : :error, 'Checking Availability on Wayback Machine', label)
        end

        def cdx_status(cdx_status, urls)
          if urls.empty?
            label = cdx_status == 'timeout' ? 'Timeout' : 'Not Found'
            row(:error, 'Fetching URLs from CDX', label)
            return
          end

          row(:error, 'Fetching URLs from CDX', 'Timeout') if cdx_status == 'timeout_with_fallback'
          return row(:plus, 'Fetching URLs from CDX', "#{urls.length} (reduced query)") if cdx_status == 'found_reduced'

          if cdx_status == 'found_partial_timeout'
            return row(:plus, 'Fetching URLs from CDX',
                       "#{urls.length} (partial, timeout)")
          end

          row(:info, 'Fetching URLs from CDX', urls.length) unless cdx_status == 'timeout_with_fallback'
        end

        def fallback_used(count)
          row(:plus, 'Using availability snapshot fallback', count)
        end

        def urls_preview(urls)
          list = Array(urls).compact
          return if list.empty?

          UI.tree_header('Wayback URL Preview')
          rows = list.first(Wayback::PREVIEW_LIMIT).map { |url| ['URL', url] }
          UI.tree_rows(rows)
          remaining = list.length - Wayback::PREVIEW_LIMIT
          UI.tree_rows([['More', remaining]]) if remaining.positive?
        end

        def row(type, label, value)
          UI.row(type, label, value, label_width: Wayback::WAYBACK_ROW_LABEL_WIDTH)
        end
      end
    end
  end
end
