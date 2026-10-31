require "uri"
require "set"
require "./limits"
require "./path_helpers"
require "./fields"

module Nokizaru
  module DirRec
    # The enumeration plan: the seed URLs (high-signal paths plus crawler-derived
    # paths), the prioritized word list, and the file extensions. Planning is
    # pure; crawler_paths are supplied already extracted from the crawler result.
    struct UrlPlan
      getter seed_urls : Array(String)
      getter crawler_paths : Array(String)
      getter words : Array(String)
      getter extensions : Array(String)
      getter estimated_total : Int32

      def initialize(@seed_urls, @crawler_paths, @words, @extensions, @estimated_total)
      end
    end

    module Plan
      extend self

      EXTENSION_WORTHY_WORDS = %w[index admin login api config backup db upload dashboard]

      # Complexity: O(S) to build seeds, O(W log W) to prioritize the words (one
      # sort), O(E) for extensions; the per-word key is computed once each.
      # context_paths are extra seeds from cross-module feeds (wayback history,
      # JS routes). extra_seed_urls are absolute URLs on a different origin (an
      # alt web port the port scan found), added to the seed set as-is.
      def build(normalized_target : String, words : Array(String), filext : String, crawler_paths : Array(String), context_paths : Array(String) = [] of String, extra_seed_urls : Array(String) = [] of String) : UrlPlan
        seeds = build_seed_urls(normalized_target, crawler_paths, context_paths)
        seeds.concat(extra_seed_urls)
        seeds.uniq!
        prioritized = prioritized_words(normalized_target, words, seeds)
        extensions = file_extensions(filext)
        total = seeds.size + prioritized.size + prioritized.size * extensions.size
        UrlPlan.new(seeds, crawler_paths, prioritized, extensions, total)
      end

      def file_extensions(filext : String) : Array(String)
        value = filext.strip
        return [] of String if value.empty?

        value.split(',').map(&.strip).reject(&.empty?)
      end

      private def build_seed_urls(target : String, crawler_paths : Array(String), context_paths : Array(String)) : Array(String)
        base = Fields.normalize_target_base(target)
        paths = HIGH_SIGNAL_PATHS + crawler_paths + context_paths
        paths.uniq!
        seeds = paths.map { |path| PathHelpers.join_url(base, path) }
        seeds.uniq!
        seeds
      end

      private def prioritized_words(target : String, words : Array(String), seed_urls : Array(String)) : Array(String)
        seeded = seeded_paths(seed_urls)
        words.uniq.sort_by! do |word|
          encoded = PathHelpers.encode_path_word(word)
          {seeded.includes?(encoded) ? 1 : 0, extension_worthy?(word) ? 0 : 1, encoded.size}
        end
      rescue
        words.uniq
      end

      private def seeded_paths(seed_urls : Array(String)) : Set(String)
        seed_urls.compact_map do |url|
          URI.parse(url).path.lchop("/")
        rescue
          nil
        end.to_set
      end

      private def extension_worthy?(word : String) : Bool
        value = word.downcase
        return false if value.empty? || value.includes?(".")

        HIGH_SIGNAL_PATHS.any?(&.lchop("/").starts_with?(value)) ||
          EXTENSION_WORTHY_WORDS.includes?(value)
      end
    end
  end
end
