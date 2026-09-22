# frozen_string_literal: true

require 'timeout'

module Nokizaru
  module Modules
    module Subdomains
      module_function

      class ResultSet
        def initialize(hostname, valid_pattern)
          @hostname = hostname.to_s
          @valid_pattern = valid_pattern
          @seen = {}
          @mutex = Mutex.new
        end

        def concat(values)
          prepared = Array(values).filter_map { |value| normalize(value) }
          return self if prepared.empty?

          @mutex.synchronize do
            prepared.each { |entry| @seen[entry] = true }
          end
          self
        end

        def to_a
          @mutex.synchronize { @seen.keys.dup }
        end

        private

        def normalize(value)
          candidate = value.to_s.strip
          return nil if candidate.empty?
          return nil unless in_hostname_scope?(candidate)
          return nil unless candidate.match?(@valid_pattern)

          candidate
        end

        def in_hostname_scope?(candidate)
          candidate == @hostname || candidate.end_with?(".#{@hostname}")
        end
      end

      VENDOR_CAPS = {
        'AnubisDB' => 10.0,
        'ThreatMiner' => 8.0,
        'crt.sh' => 8.0,
        'AlienVault' => 8.0,
        'Chaos' => 8.0
      }.freeze

      def enumerate(hostname, timeout, progress: nil, health: nil)
        found = ResultSet.new(hostname, VALID)
        overall_budget = timeout.to_f.clamp(5.0, 30.0)
        vendor_default = [overall_budget, 12.0].min
        vendor_timeouts = build_vendor_timeouts(vendor_default)
        base_http = build_subdomain_http(vendor_default)
        jobs = subdomain_jobs(hostname, found)
        elapsed = run_subdomain_jobs(jobs, base_http, vendor_timeouts, overall_budget, progress: progress, found: found)
        health&.replace(SubdomainModules::Base.provider_health(jobs.map(&:first), elapsed))
        finalize_subdomains(found, hostname)
      end

      def build_vendor_timeouts(vendor_default)
        defaulted = Hash.new(vendor_default)
        VENDOR_CAPS.each { |name, cap| defaulted[name] = [vendor_default, cap].min }
        defaulted
      end

      def build_subdomain_http(vendor_default)
        Nokizaru::HTTPClient.build(
          timeout_s: vendor_default,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: false,
          persistent: true,
          verify_ssl: true
        ).with(max_retries: 0)
      end

      def run_subdomain_jobs(jobs, base_http, vendor_timeouts, overall_budget, progress: nil, found: nil)
        queue = Queue.new
        jobs.each { |job| queue << job }
        deadline = monotonic_time + overall_budget
        tracker = {
          total: jobs.length, completed: Concurrent::AtomicFixnum.new(0), progress: progress, found: found,
          elapsed: {}, mutex: Mutex.new
        }
        worker_count = [10, jobs.length].min
        workers = Array.new(worker_count) do
          Thread.new { worker_loop(queue, deadline, base_http, vendor_timeouts, tracker) }
        end
        workers.each(&:join)
        finish_timed_out_jobs(queue, tracker)
        tracker[:elapsed]
      end

      def worker_loop(queue, deadline, base_http, vendor_timeouts, tracker = nil)
        loop do
          break unless remaining_budget(deadline).positive?

          job = pop_job(queue)
          break unless job

          run_subdomain_job(job, base_http, vendor_timeouts, deadline, tracker)
          update_subdomain_progress(tracker) if tracker
        end
      end

      def finish_timed_out_jobs(queue, tracker)
        while (job = pop_job(queue))
          SubdomainModules::Base.status_error(job.first, 'timeout', 'shared provider deadline exceeded before start')
          update_subdomain_progress(tracker)
        end
      end

      def update_subdomain_progress(tracker)
        current = tracker[:completed].increment
        found_count = tracker[:found]&.to_a&.length.to_i
        tracker[:progress]&.update(
          :sub,
          stage: 'providers', current: current, total: tracker[:total], found: found_count
        )
      end

      def pop_job(queue)
        queue.pop(true)
      rescue StandardError
        nil
      end

      def run_subdomain_job(job, base_http, vendor_timeouts, deadline = nil, tracker = nil)
        name, fn = job
        started_at = monotonic_time
        timeout = [vendor_timeouts[name], remaining_budget(deadline)].compact.min
        return provider_timeout(name, 'shared provider deadline exceeded before start') unless timeout&.positive?

        http = base_http.with(timeout: timeout_profile(timeout))
        Timeout.timeout(timeout) { fn.call(http) }
      rescue Timeout::Error
        provider_timeout(name, 'provider execution deadline exceeded')
      rescue StandardError => e
        SubdomainModules::Base.exception(name, e)
        Log.write("[subdom.worker] #{name} unhandled exception = #{e}")
      ensure
        record_provider_elapsed(tracker, name, started_at) if tracker && started_at
      end

      def record_provider_elapsed(tracker, name, started_at)
        elapsed = [monotonic_time - started_at, 0.0].max
        tracker[:mutex].synchronize { tracker[:elapsed][name] = elapsed }
      end

      def provider_timeout(name, reason)
        SubdomainModules::Base.status_error(name, 'timeout', reason)
        Log.write("[subdom.worker] #{name} timeout = #{reason}")
      end

      def remaining_budget(deadline)
        deadline ? deadline - monotonic_time : nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def timeout_profile(timeout)
        {
          connect_timeout: [5, timeout].min,
          read_timeout: timeout,
          write_timeout: [5, timeout].min,
          operation_timeout: timeout
        }
      end

      def finalize_subdomains(found, hostname)
        values = found.to_a
        values.select! { |item| item == hostname || item.end_with?(".#{hostname}") }
        values.select! { |item| item.match?(VALID) }
        values.uniq!
        values.sort
      end
    end
  end
end
