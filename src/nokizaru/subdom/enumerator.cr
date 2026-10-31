require "wait_group"
require "./provider"
require "../progress_reporter"

module Nokizaru
  module Subdom
    # The in-scope, deduplicated set of discovered names. A name is kept only if
    # it is the host or a subdomain of it and matches the permissive hostname
    # charset. A Set gives O(1) dedup; providers add from fibers so adds are
    # serialized by a Mutex.
    class ResultSet
      VALID = /\A[A-Za-z0-9._~()'!*:@,;+?-]*\z/

      def initialize(@host : String)
        @seen = Set(String).new
        @mutex = Mutex.new
      end

      def add(values : Array(String)) : Nil
        @mutex.synchronize do
          values.each do |value|
            name = normalize(value)
            @seen << name if name
          end
        end
      end

      def sorted : Array(String)
        @mutex.synchronize { @seen.to_a.sort }
      end

      def size : Int32
        @mutex.synchronize { @seen.size }
      end

      private def normalize(value : String) : String?
        candidate = value.strip
        return nil if candidate.empty?
        return nil if candidate.starts_with?("*.") # a wildcard entry is not a concrete host
        return nil unless in_scope?(candidate)
        return nil unless candidate.matches?(VALID)

        candidate
      end

      private def in_scope?(candidate : String) : Bool
        candidate == @host || candidate.ends_with?(".#{@host}")
      end
    end

    # O(providers) dispatch through a fixed pool, joined before returning. Every
    # request shares the scan deadline and its provider's shorter absolute cap.
    class Enumerator
      WORKER_LIMIT       =   10
      MIN_BUDGET         =  5.0
      MAX_BUDGET         = 30.0
      VENDOR_DEFAULT_CAP = 12.0
      # crt.sh is slow (its backend can take 15-30s) but the highest-value
      # keyless source, so it gets a longer per-provider cap than the default;
      # it still shares the overall scan deadline and runs concurrently.
      VENDOR_CAPS = {"AnubisDB" => 10.0, "crt.sh" => 25.0, "AlienVault" => 8.0, "Chaos" => 8.0}

      def initialize(@providers : Array(Provider), @clock : Proc(Time::Instant) = -> { Time.instant })
      end

      def run(host : String, pool : Http::Pool, keys : Hash(String, String), timeout : Float64, progress : ProgressReporter = ProgressReporter::NULL, extra : Array(String) = [] of String) : {Array(String), Array(Outcome)}
        found = ResultSet.new(host)
        found.add(extra)
        return {found.sorted, [] of Outcome} if @providers.empty?

        budget = timeout.clamp(MIN_BUDGET, MAX_BUDGET)
        deadline = @clock.call + budget.seconds
        outcomes = Array(Outcome?).new(@providers.size, nil)
        concurrency = {WORKER_LIMIT, @providers.size}.min
        cursor = Atomic(Int32).new(0)
        waiter = WaitGroup.new(concurrency)
        done = Atomic(Int32).new(0)

        concurrency.times do
          spawn do
            while (index = cursor.add(1)) < @providers.size
              provider = @providers[index]
              outcome = run_provider(provider, host, pool, keys, budget: budget, deadline: deadline)
              found.add(outcome.names)
              outcomes[index] = outcome
              report(progress, done.add(1) + 1, found)
            end
          ensure
            waiter.done
          end
        end
        waiter.wait
        {found.sorted, outcomes.compact}
      end

      private def run_provider(provider : Provider, host : String, pool : Http::Pool, keys : Hash(String, String), *, budget : Float64, deadline : Time::Instant) : Outcome
        if @clock.call >= deadline
          return Outcome.new(provider.name, STATUS_TIMEOUT, [] of String, "shared provider deadline exceeded before start", 0.0)
        end

        provider.run(host, pool, keys, vendor_timeout(provider.name, budget), clock: @clock, deadline: deadline)
      end

      # Publishes "<completed>/<total> found <n>" as each provider finishes,
      # matching the Ruby subdomain rail. Skipped when no rail listens.
      private def report(progress : ProgressReporter, completed : Int32, found : ResultSet) : Nil
        return unless progress.active?

        progress.report(stage: "querying", detail: "#{completed}/#{@providers.size} found #{found.size}")
      end

      private def vendor_timeout(name : String, budget : Float64) : Float64
        cap = VENDOR_CAPS[name]? || VENDOR_DEFAULT_CAP
        {budget, cap}.min
      end
    end
  end
end
