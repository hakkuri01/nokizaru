# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'

module Nokizaru
  module Modules
    module Crawler
      module Concurrency
        private

        def each_concurrently(items)
          experimental_warnings = Warning[:experimental]
          Warning[:experimental] = false
          Sync do
            barrier = Async::Barrier.new
            semaphore = Async::Semaphore.new(Crawler::MAX_FETCH_WORKERS, parent: barrier)
            items.each do |item|
              semaphore.async(item) { |_task, value| yield(value) }
            end
            barrier.wait
          end
        ensure
          Warning[:experimental] = experimental_warnings
        end
      end
    end
  end
end
