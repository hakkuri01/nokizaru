# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      class LazyDirectoryQueue
        include PathHelpers

        def initialize(scan, runtime)
          @scan = scan
          @runtime = runtime
          @mutex = Mutex.new
          @seen = Set.new
          @stage = :seed
          @index = 0
          @ext_word_index = 0
          @ext_index = 0
        end

        def pop(*)
          @mutex.synchronize do
            next_url || raise(ThreadError)
          end
        end

        private

        def next_url
          case @stage
          when :seed then next_seed_url
          when :base then next_base_word_url
          when :extension then next_extension_url
          end
        end

        def next_seed_url
          seeds = @scan[:url_plan][:seed_urls]
          while @index < seeds.length
            url = unseen(seeds[@index])
            @index += 1
            return url if url
          end

          switch_stage(:base)
        end

        def next_base_word_url
          words = @scan[:url_plan][:words]
          while @index < words.length
            word = words[@index]
            @index += 1
            url = unseen(join_url(@scan[:normalized_target], encode_path_word(word)))
            return url if url
          end

          switch_stage(:extension)
        end

        def next_extension_url
          return nil unless extension_phase_allowed?

          words = @scan[:url_plan][:words]
          exts = @scan[:url_plan][:extensions]
          while !exts.empty? && @ext_word_index < words.length
            @ext_word_index += 1 while @ext_word_index < words.length && words[@ext_word_index].to_s.include?('.')
            return nil if @ext_word_index >= words.length

            url = unseen(extension_candidate(words, exts))
            return url if url
          end

          nil
        end

        def extension_candidate(words, exts)
          word = encode_path_word(words[@ext_word_index])
          ext = exts[@ext_index]
          advance_extension_cursor(words, exts)
          join_url(@scan[:normalized_target], "#{word}.#{ext}")
        end

        def extension_phase_allowed?
          return true unless @runtime.is_a?(Hash)

          state = @runtime[:extension_state]
          state.is_a?(Hash) && state[:enabled]
        end

        def advance_extension_cursor(words, exts)
          @ext_index += 1
          return if @ext_index < exts.length

          @ext_index = 0
          @ext_word_index += 1
          @ext_word_index += 1 while @ext_word_index < words.length && words[@ext_word_index].to_s.include?('.')
        end

        def switch_stage(next_stage)
          @stage = next_stage
          @index = 0
          next_url
        end

        def unseen(url)
          return nil if url.to_s.empty? || @seen.include?(url)

          @seen.add(url)
          url
        end
      end
    end
  end
end
