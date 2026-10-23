require "wait_group"
require "./limits"
require "./sample"
require "./sampler"
require "./soft404"
require "./context"
require "../http/pool"
require "../progress_reporter"

module Nokizaru
  module DirRec
    # One observed candidate: the response plus when it was seen (for ordering
    # and the time-to-first-actionable stat). Re-decided at finalize against the
    # final soft-404 baseline.
    record Observation,
      url : String,
      status : Int32,
      sample : Sample,
      observed_count : Int32,
      observed_at : Time::Instant

    # The mutable scan state and the worker pool. Route B: a fixed bounded set of
    # fibers, each with its own HTTP connection to the (single) target, drains the
    # lazy queue; per response it learns the soft-404 baseline, updates the WAF
    # context, and records the observation. Classification is done once at
    # finalize (Results), so no mid-scan adaptation is needed. Complexity: O(1)
    # work per response under the shared Mutex; memory is the fixed-size summary
    # per finding candidate, never a body.
    class Runtime
      getter responses = [] of Tuple(String, Int32)
      getter all_found = [] of String
      getter signal_responses = [] of Tuple(String, Int32)
      getter observations = [] of Observation
      getter error_kinds = Hash(String, Int32).new(0)
      getter context : ConfidenceContext
      getter start_time : Time::Instant
      getter soft_404_baseline : Baseline?
      getter success = 0
      getter errors = 0
      getter count = 0

      def initialize(@scan_target : String, @normalized_target : String, @soft_404_baseline : Baseline?, @context : ConfidenceContext)
        @state = Soft404::State.new
        @learning = Soft404::Learning.new
        @mutex = Mutex.new
        @start_time = Time.instant
        @progress = ProgressReporter::NULL
        @total = 0
      end

      def run(queue : LazyQueue, concurrency : Int32, options : Http::Options, progress : ProgressReporter = ProgressReporter::NULL, total : Int32 = 0) : Nil
        @progress = progress
        @total = total
        waiter = WaitGroup.new(concurrency)
        concurrency.times do
          spawn do
            pool = Http::Pool.new
            begin
              worker_loop(queue, pool, options)
            ensure
              pool.shutdown
              waiter.done
            end
          end
        end
        waiter.wait
      end

      private def worker_loop(queue : LazyQueue, pool : Http::Pool, options : Http::Options) : Nil
        loop do
          url = queue.pop
          break if url.nil?

          begin
            result = pool.get(url, options)
            result.error? ? record_error(result) : record_success(url, result)
          rescue
            record_exception
          end
        end
      end

      private def record_success(url : String, result : Http::Result) : Nil
        status = result.status
        return if status.nil?

        sample = Sampler.sample(result, url)
        counts = @mutex.synchronize do
          @success += 1
          @count += 1
          @responses << {url, status}
          @signal_responses << {url, status} if SOFT_404_SAMPLE_STATUSES.includes?(status)
          @all_found << url if FINDING_CANDIDATE_STATUSES.includes?(status) && url != "#{@scan_target}/"
          observe_candidate(url, status, sample)
          counts_snapshot
        end
        report_progress(counts)
      end

      private def observe_candidate(url : String, status : Int32, sample : Sample?) : Nil
        return unless FINDING_CANDIDATE_STATUSES.includes?(status)

        learn_baseline(sample)
        @context.update!(status, sample, @soft_404_baseline)
        @observations << Observation.new(url, status, sample, @count, Time.instant) if sample
      end

      private def learn_baseline(sample : Sample?) : Nil
        return if sample.nil?
        return unless Soft404.soft_404_active?(@state, @soft_404_baseline)

        Soft404.record_sample!(@state)
        @soft_404_baseline = Soft404.learn(sample, @soft_404_baseline, @learning)
        Soft404.disable_if_unstable!(@state, @soft_404_baseline, @learning)
      end

      private def record_error(result : Http::Result) : Nil
        kind = classify_error(result)
        counts = @mutex.synchronize do
          @errors += 1
          @error_kinds[kind] += 1
          @count += 1
          counts_snapshot
        end
        report_progress(counts)
      end

      private def record_exception : Nil
        counts = @mutex.synchronize do
          @errors += 1
          @error_kinds["other"] += 1
          @count += 1
          counts_snapshot
        end
        report_progress(counts)
      end

      # A consistent view of the live counters, captured under the mutex so the
      # rail detail never shows a torn read. {count, success, errors, found}.
      private def counts_snapshot : Tuple(Int32, Int32, Int32, Int32)
        {@count, @success, @errors, @all_found.size}
      end

      # Publishes the live rail detail ("123/5000 avg 45.2r/s ok 120 err 3 found
      # 12"), matching the Ruby dir progress line. Skipped when no rail listens.
      private def report_progress(counts : Tuple(Int32, Int32, Int32, Int32)) : Nil
        return unless @progress.active?

        count, success, errors, found = counts
        elapsed = (Time.instant - @start_time).total_seconds
        rps = elapsed > 0 ? (count / elapsed).round(1) : 0.0
        @progress.report(detail: "#{count}/#{@total} avg #{rps}r/s ok #{success} err #{errors} found #{found}")
      end

      private def classify_error(result : Http::Result) : String
        case result.error_kind
        when .timeout?                             then "timeout"
        when .tls?                                 then "tls"
        when .connection_refused?, .closed?, .dns? then "connection"
        else                                            "other"
        end
      end
    end
  end
end
