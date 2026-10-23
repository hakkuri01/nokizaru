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
        prioritized = Array(dir_result['prioritized_found']).map(&:to_s)
        return prioritized unless prioritized.empty?

        Array(dir_result['confirmed_found']).map(&:to_s)
      end

      def interesting_paths_finding(interesting)
        {
          'id' => 'dir.interesting_paths',
          'severity' => 'low',
          'title' => 'Prioritized interesting paths discovered',
          'evidence' => preview_interesting_paths(interesting),
          'recommendation' => 'Review prioritized endpoints first and validate low-confidence paths via export output.',
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
