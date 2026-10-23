require "wait_group"
require "./provider"
require "../progress_reporter"

module Nokizaru
  module Subdom
    # The in-scope, deduplicated set of discovered names. A name is kept only if
    # it is the host or a subdomain of it and matches the permissive hostname
    # charset (ports ResultSet + VALID). A Set gives O(1) dedup; providers add
    # from fibers so adds are serialized by a Mutex.
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
        return nil unless in_scope?(candidate)
        return nil unless candidate.matches?(VALID)

        candidate
      end

      private def in_scope?(candidate : String) : Bool
        candidate == @host || candidate.ends_with?(".#{@host}")
      end
    end

    # Runs the providers over a bounded fiber pool and collects their outcomes
    # plus the scoped result set. Each provider gets a per-vendor timeout as its
    # HTTP deadline; the slow public sources are capped shorter (VENDOR_CAPS).
    #
    # ponytail: the Ruby runner also wrapped each provider in Timeout.timeout
    # and enforced one overall wall-clock budget with mid-flight cancellation.
    # Here the per-request HTTP timeout bounds each provider and the worker cap
    # bounds how many run at once, so the total is bounded without cancelling an
    # in-flight fiber; a true overall-deadline cancel is deferred to the
    # benchmarking pass. Complexity: O(providers) runs, at most WORKER_LIMIT in
    # flight, each O(1) bounded requests.
    class Enumerator
      WORKER_LIMIT       =   10
      MIN_BUDGET         =  5.0
      MAX_BUDGET         = 30.0
      VENDOR_DEFAULT_CAP = 12.0
      VENDOR_CAPS        = {"AnubisDB" => 10.0, "ThreatMiner" => 8.0, "crt.sh" => 8.0, "AlienVault" => 8.0, "Chaos" => 8.0}

      def initialize(@providers : Array(Provider))
      end

      def run(host : String, pool : Http::Pool, keys : Hash(String, String), timeout : Float64, progress : ProgressReporter = ProgressReporter::NULL) : {Array(String), Array(Outcome)}
        return {[] of String, [] of Outcome} if @providers.empty?

        vendor_default = {timeout.clamp(MIN_BUDGET, MAX_BUDGET), VENDOR_DEFAULT_CAP}.min
        found = ResultSet.new(host)
        outcomes = Array(Outcome?).new(@providers.size, nil)
        concurrency = {WORKER_LIMIT, @providers.size}.min
        slots = Channel(Nil).new(concurrency)
        concurrency.times { slots.send(nil) }
        waiter = WaitGroup.new(@providers.size)
        done = Atomic(Int32).new(0)

        @providers.each_with_index do |provider, index|
          slots.receive
          spawn do
            outcome = provider.run(host, pool, keys, vendor_timeout(provider.name, vendor_default))
            found.add(outcome.names)
            outcomes[index] = outcome
          ensure
            slots.send(nil)
            report(progress, done.add(1) + 1, found)
            waiter.done
          end
        end
        waiter.wait
        {found.sorted, outcomes.compact}
      end

      # Publishes "<completed>/<total> found <n>" as each provider finishes,
      # matching the Ruby subdomain rail. Skipped when no rail listens.
      private def report(progress : ProgressReporter, completed : Int32, found : ResultSet) : Nil
        return unless progress.active?

        progress.report(stage: "querying", detail: "#{completed}/#{@providers.size} found #{found.size}")
      end

      private def vendor_timeout(name : String, default : Float64) : Float64
        cap = VENDOR_CAPS[name]?
        cap ? {default, cap}.min : default
      end
    end
  end
end
