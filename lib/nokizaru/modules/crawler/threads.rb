# frozen_string_literal: true

module Nokizaru
  module Modules
    module Crawler
      # Shared thread pool helpers for crawler fan-out jobs
      module Threads
        private

        def each_in_threads(items, &block)
          queue = Queue.new
          items.each { |item| queue << item }
          threads = Array.new(worker_count(items.length)) { Thread.new { consume_queue(queue, &block) } }
          threads.each(&:join)
        end

        def worker_count(item_count)
          [item_count, Crawler::MAX_FETCH_WORKERS].min
        end

        def consume_queue(queue)
          loop do
            item = pop_queue_item(queue)
            break if item.nil?

            yield(item)
          end
        end

        def pop_queue_item(queue)
          queue.pop(true)
        rescue ThreadError
          nil
        end
      end
    end
  end
end
