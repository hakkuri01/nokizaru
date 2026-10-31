require "../finding"
require "../modules/dirrec"

module Nokizaru
  module Findings
    # Flags prioritized discovered paths that look sensitive (admin, backup,
    # .git, .env, config, debug, swagger, api, graphql). Consumes the typed
    # directory enumeration result, preferring prioritized paths and falling back
    # to confirmed ones.
    module DirectoryRules
      extend self

      INTERESTING_PATH = /\/(admin|backup|\.git|\.env|config|debug|swagger|api|graphql)\b/i

      def call(result : Modules::DirectoryEnum::Result?) : Array(Finding)
        return [] of Finding if result.nil?

        interesting = discovered_paths(result).select(&.matches?(INTERESTING_PATH))
        interesting.empty? ? [] of Finding : [interesting_finding(interesting)]
      end

      private def discovered_paths(result : Modules::DirectoryEnum::Result) : Array(String)
        result.prioritized_found.empty? ? result.confirmed_found : result.prioritized_found
      end

      private def interesting_finding(interesting : Array(String)) : Finding
        Finding.new(
          id: "dir.interesting_paths",
          severity: "low",
          title: "Prioritized interesting paths discovered",
          source_module: "directory_enum",
          tags: ["content", "discovery"],
          evidence: preview(interesting),
          recommendation: "Review prioritized endpoints first and validate low-confidence paths via export output.",
        )
      end

      private def preview(interesting : Array(String)) : String
        preview = interesting.first(20).join(", ")
        interesting.size > 20 ? "#{preview}…" : preview
      end
    end
  end
end
