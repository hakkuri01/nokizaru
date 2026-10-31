require "wait_group"
require "./limits"
require "./sample"
require "./sampler"
require "./soft404"
require "./context"
require "./adaptive_policy"
require "./queue"
require "../scan_stop"
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

    # A blocking coordinator admits work up to the adaptive cap. Workers keep
    # their connections, and already admitted requests drain on stop/downshift.
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
      getter policy : AdaptivePolicy
      getter peak_in_flight = 0

      def initialize(@scan_target : String, @normalized_target : String, @soft_404_baseline : Baseline?, @context : ConfidenceContext, *, policy : AdaptivePolicy? = nil, @transport : Proc(String, Http::Options, Http::Result)? = nil, @stop : ScanStop = ScanStop.new, @pool_template : Http::Pool = Http::Pool.new)
        @state = Soft404::State.new
        @learning = Soft404::Learning.new
        @policy = policy || AdaptivePolicy.new(1, DEFAULT_TIMEOUT, @soft_404_baseline)
        @start_time = @policy.start_time
        @progress = ProgressReporter::NULL
        @total = 0
      end

      def run(queue : LazyQueue, concurrency : Int32, options : Http::Options, progress : ProgressReporter = ProgressReporter::NULL, total : Int32 = 0) : Nil
        @progress = progress
        @total = total
        jobs = Channel(Tuple(String, Http::Options)).new
        completed = Channel(Tuple(String, Http::Result)).new(concurrency)
        waiter = WaitGroup.new(concurrency)
        concurrency.times do
          spawn do
            # Each worker needs its own connections, but not its own policy: the
            # template carries the scan's TLS choice and destination guard.
            pool = @pool_template.derive
            begin
              worker_loop(jobs, completed, pool)
            ensure
              begin
                pool.shutdown
              ensure
                waiter.done
              end
            end
          end
        end
        begin
          dispatch(queue, jobs, completed, options)
        ensure
          jobs.close
          waiter.wait
        end
      end

      private def worker_loop(jobs, completed, pool : Http::Pool) : Nil
        while job = jobs.receive?
          url, options = job
          begin
            transport = @transport
            result = transport ? transport.call(url, options) : pool.get(url, options)
          rescue
            result = Http::Result.failure(Http::ErrorKind::Other, "Directory request failed")
          end
          completed.send({url, result})
        end
      end

      private def dispatch(queue, jobs, completed, options : Http::Options) : Nil
        active = dispatched = 0
        loop do
          # A stopped scan admits no further candidates; the probes already in
          # flight are drained below so every worker socket still closes.
          until @stop.stopped? || active >= @policy.stats.adaptive_concurrency || @policy.stopped?(dispatched)
            queue.extension_enabled = @policy.stats.extension_phase_enabled?
            url = queue.pop
            break if url.nil?
            jobs.send({url, request_options(options)})
            dispatched += 1
            active += 1
            @peak_in_flight = Math.max(@peak_in_flight, active)
          end
          break if active == 0

          url, result = completed.receive
          active -= 1
          result.error? ? record_error(result) : record_success(url, result)
          report_progress(counts_snapshot)
        end
      end

      private def request_options(options : Http::Options) : Http::Options
        Http::Options.new(headers: options.headers, timeout_s: @policy.timeout_s,
          follow_redirects: options.follow_redirects?,
          max_redirects: options.max_redirects, body: options.body, scope_check: options.scope_check)
      end

      private def record_success(url : String, result : Http::Result) : Nil
        status = result.status
        return if status.nil?

        begin
          sample = Sampler.sample(result, url)
          prioritized = observe_candidate(url, status, sample)
        rescue
          record_error(Http::Result.failure(Http::ErrorKind::Other, "Directory response processing failed"))
          return
        end
        @success += 1
        @count += 1
        @responses << {url, status}
        @signal_responses << {url, status} if SOFT_404_SAMPLE_STATUSES.includes?(status)
        @all_found << url if FINDING_CANDIDATE_STATUSES.includes?(status) && url != "#{@scan_target}/"
        @policy.observe(status, nil, prioritized, @context.snapshot)
      end

      private def observe_candidate(url : String, status : Int32, sample : Sample?) : Bool
        return false unless FINDING_CANDIDATE_STATUSES.includes?(status)

        learn_baseline(sample)
        @context.update!(status, sample, @soft_404_baseline)
        decision = Confidence.finding_confidence(url, status, sample, @soft_404_baseline, @normalized_target)
        prioritized = @context.adjust(decision, url, @context.snapshot).level != "low"
        @observations << Observation.new(url, status, sample, @count + 1, @policy.now) if sample
        prioritized
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
        @errors += 1
        @error_kinds[kind] += 1
        @count += 1
        @policy.observe(nil, kind, false, @context.snapshot)
      end

      # Only the coordinator mutates counters; workers publish through a channel
      private def counts_snapshot : Tuple(Int32, Int32, Int32, Int32)
        {@count, @success, @errors, @all_found.size}
      end

      # Publishes the live rail detail ("123/5000 avg 45.2r/s ok 120 err 3 found
      # 12"), matching the Ruby dir progress line. Skipped when no rail listens.
      private def report_progress(counts : Tuple(Int32, Int32, Int32, Int32)) : Nil
        return unless @progress.active?

        count, success, errors, found = counts
        elapsed = @policy.elapsed_seconds
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
