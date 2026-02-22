# frozen_string_literal: true

module Nokizaru
  module Findings
    # Directory enumeration findings rules
    module DirectoryRules
      module_function

      INTERESTING_PATH_RE = %r{/(admin|backup|\.git|\.env|config|debug|swagger|api|graphql)\b}i

      def call(dir_result)
        return [] unless dir_result.is_a?(Hash)

        interesting = discovered_paths(dir_result).grep(INTERESTING_PATH_RE)
        return [] if interesting.empty?

        [interesting_paths_finding(interesting)]
      end

      def discovered_paths(dir_result)
        status_map = dir_result['by_status'].is_a?(Hash) ? dir_result['by_status'] : {}
        found = high_signal_paths(status_map)
        return found unless found.empty?

        Array(dir_result['found']).map(&:to_s)
      end

      def high_signal_paths(status_map)
        statuses = %w[200 204 401 403 405 500]
        statuses.flat_map { |status| Array(status_map[status]) }.map(&:to_s)
      end

      def interesting_paths_finding(interesting)
        {
          'id' => 'dir.interesting_paths',
          'severity' => 'low',
          'title' => 'Interesting paths discovered',
          'evidence' => preview_interesting_paths(interesting),
          'recommendation' => 'Review discovered endpoints for unintended exposure.',
          'module' => 'directory_enum',
          'tags' => %w[content discovery]
        }
      end

      def preview_interesting_paths(interesting)
        preview = interesting.first(20).join(', ')
        interesting.length > 20 ? "#{preview}…" : preview
      end
    end
  end
end
