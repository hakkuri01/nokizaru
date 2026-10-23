require "wait_group"
require "./limits"

module Nokizaru
  module Crawler
    # Runs a block over items with a bounded fiber pool, porting
    # crawler/concurrency.rb (async semaphore + barrier). A Channel of
    # MAX_FETCH_WORKERS tokens caps how many fibers run at once; a WaitGroup joins
    # them. Complexity: O(items) runs, at most MAX_FETCH_WORKERS concurrent, each
    # bounded by the per-request HTTP timeout. The block may mutate shared state,
    # so callers guard it with a Mutex.
    module Concurrency
      extend self

      def each_concurrently(items : Array(T), &block : T ->) : Nil forall T
        return if items.empty?

        concurrency = {MAX_FETCH_WORKERS, items.size}.min
        slots = Channel(Nil).new(concurrency)
        concurrency.times { slots.send(nil) }
        waiter = WaitGroup.new(items.size)
        items.each do |item|
          slots.receive
          spawn do
            block.call(item)
          ensure
            slots.send(nil)
            waiter.done
          end
        end
        waiter.wait
      end
    end
  end
end
