require "wait_group"
require "./limits"
require "./fetcher"

module Nokizaru
  module Crawler
    # Each worker owns its transport so same-origin requests do not share a
    # Client lock. O(1) cursor acquisition per URL, O(C) connections for C workers;
    # pools are cleared on origin changes and closed when the batch finishes.
    module Concurrency
      extend self

      def each_concurrently(items : Array(String), &block : String, Fetcher ->) : Nil
        return if items.empty?

        concurrency = {MAX_FETCH_WORKERS, items.size}.min
        cursor = 0
        mutex = Mutex.new
        next_item = -> do
          mutex.synchronize do
            item = items[cursor]?
            cursor += 1 if item
            item
          end
        end
        errors = Channel(Exception).new(concurrency)
        waiter = WaitGroup.new(concurrency)
        concurrency.times do
          spawn do
            run_worker(next_item, &block)
          rescue error
            errors.send(error)
          ensure
            waiter.done
          end
        end
        waiter.wait
        errors.close
        if error = errors.receive?
          raise error
        end
      end

      private def run_worker(next_item : Proc(String?), &block : String, Fetcher ->) : Nil
        pool = Http::Pool.new
        fetcher = Fetcher.new(pool, worker_local: true)
        begin
          while item = next_item.call
            block.call(item, fetcher)
          end
        ensure
          pool.shutdown
        end
      end
    end
  end
end
