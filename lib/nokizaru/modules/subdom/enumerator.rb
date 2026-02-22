# frozen_string_literal: true

require 'concurrent'

module Nokizaru
  module Modules
    # Concurrency helpers for passive subdomain enumeration
    module Subdomains
      module_function

      VENDOR_CAPS = {
        'AnubisDB' => 10.0,
        'ThreatMiner' => 8.0,
        'crt.sh' => 8.0,
        'AlienVault' => 8.0,
        'Chaos' => 8.0
      }.freeze

      def enumerate(hostname, timeout, conf_path)
        found = Concurrent::Array.new
        overall_budget = timeout.to_f.clamp(5.0, 30.0)
        vendor_default = [overall_budget, 12.0].min
        vendor_timeouts = build_vendor_timeouts(vendor_default)
        base_http = build_subdomain_http(vendor_default)
        jobs = subdomain_jobs(hostname, conf_path, found)
        run_subdomain_jobs(jobs, base_http, vendor_timeouts, overall_budget)
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
          follow_redirects: true,
          persistent: true,
          verify_ssl: true
        )
      end

      def run_subdomain_jobs(jobs, base_http, vendor_timeouts, overall_budget)
        queue = Queue.new
        jobs.each { |job| queue << job }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + overall_budget
        worker_count = [6, jobs.length].min
        workers = Array.new(worker_count) { Thread.new { worker_loop(queue, deadline, base_http, vendor_timeouts) } }
        workers.each(&:join)
      end

      def worker_loop(queue, deadline, base_http, vendor_timeouts)
        loop do
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          job = pop_job(queue)
          break unless job

          run_subdomain_job(job, base_http, vendor_timeouts)
        end
      end

      def pop_job(queue)
        queue.pop(true)
      rescue StandardError
        nil
      end

      def run_subdomain_job(job, base_http, vendor_timeouts)
        name, fn = job
        timeout = vendor_timeouts[name]
        http = base_http.with(timeout: timeout_profile(timeout))
        fn.call(http)
      rescue StandardError => e
        UI.line(:error, "#{name} Exception : #{e}")
        Log.write("[subdom.worker] #{name} unhandled exception = #{e}")
      end

      def timeout_profile(timeout)
        {
          connect_timeout: 5,
          read_timeout: timeout,
          write_timeout: 5,
          operation_timeout: timeout
        }
      end

      def finalize_subdomains(found, hostname)
        values = found.to_a
        values.select! { |item| item.end_with?(hostname) }
        values.select! { |item| item.match?(VALID) }
        values.uniq
      end
    end
  end
end
