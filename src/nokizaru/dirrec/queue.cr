require "set"
require "./plan"
require "./path_helpers"

module Nokizaru
  module DirRec
    # The lazy candidate queue: it walks seed URLs, then base words, then the
    # word×extension product, by cursor, materializing no list and deduplicating
    # through a Set. `pop` returns nil when exhausted (the Ruby version raised
    # ThreadError). Thread-safe for the worker fibers via a Mutex. Complexity:
    # O(1) amortized per pop; memory is the seen Set plus the cursor, never the
    # full candidate space.
    class LazyQueue
      enum Stage
        Seed
        Base
        Extension
      end

      def initialize(@plan : UrlPlan, @normalized_target : String, @extension_enabled : Bool = true)
        @mutex = Mutex.new
        @seen = Set(String).new
        @stage = Stage::Seed
        @index = 0
        @ext_word_index = 0
        @ext_index = 0
      end

      def extension_enabled=(value : Bool) : Nil
        @mutex.synchronize { @extension_enabled = value }
      end

      def pop : String?
        @mutex.synchronize { next_url }
      end

      private def next_url : String?
        case @stage
        when Stage::Seed      then next_seed_url
        when Stage::Base      then next_base_word_url
        when Stage::Extension then next_extension_url
        end
      end

      private def next_seed_url : String?
        seeds = @plan.seed_urls
        while @index < seeds.size
          url = unseen(seeds[@index])
          @index += 1
          return url unless url.nil?
        end
        switch_stage(Stage::Base)
      end

      private def next_base_word_url : String?
        words = @plan.words
        while @index < words.size
          word = words[@index]
          @index += 1
          url = unseen(PathHelpers.join_url(@normalized_target, PathHelpers.encode_path_word(word)))
          return url unless url.nil?
        end
        switch_stage(Stage::Extension)
      end

      private def next_extension_url : String?
        return nil unless @extension_enabled

        words = @plan.words
        exts = @plan.extensions
        while !exts.empty? && @ext_word_index < words.size
          skip_dotted_words(words)
          return nil if @ext_word_index >= words.size

          url = unseen(extension_candidate(words, exts))
          return url unless url.nil?
        end
        nil
      end

      private def extension_candidate(words : Array(String), exts : Array(String)) : String
        word = PathHelpers.encode_path_word(words[@ext_word_index])
        ext = exts[@ext_index]
        advance_extension_cursor(words, exts)
        PathHelpers.join_url(@normalized_target, "#{word}.#{ext}")
      end

      private def advance_extension_cursor(words : Array(String), exts : Array(String)) : Nil
        @ext_index += 1
        return if @ext_index < exts.size

        @ext_index = 0
        @ext_word_index += 1
        skip_dotted_words(words)
      end

      private def skip_dotted_words(words : Array(String)) : Nil
        while @ext_word_index < words.size && words[@ext_word_index].includes?(".")
          @ext_word_index += 1
        end
      end

      private def switch_stage(next_stage : Stage) : String?
        @stage = next_stage
        @index = 0
        next_url
      end

      private def unseen(url : String) : String?
        return nil if url.empty? || @seen.includes?(url)

        @seen.add(url)
        url
      end
    end
  end
end
