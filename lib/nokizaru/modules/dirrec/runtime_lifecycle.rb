# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module RuntimeLifecycle
        private

        def init_runtime(scan)
          runtime = {
            mutex: Mutex.new,
            slot_cv: ConditionVariable.new,
            output_lock: Mutex.new,
            responses: [],
            signal_responses: [],
            found: [],
            stdout_found: [],
            confirmed_found: [],
            low_confidence_found: [],
            all_found: [],
            stop_status_code_shape: nil,
            first_actionable_at: nil,
            first_actionable_count: nil,
            redirect_signals: init_redirect_signals,
            soft_404_baseline: scan[:soft_404_baseline],
            soft_404_learning: init_soft_404_learning,
            soft_404_state: init_soft_404_state,
            confidence_context: init_confidence_context(scan),
            stats: init_stats,
            issued: 0,
            active_requests: 0,
            count: 0,
            start_time: Time.now,
            queue: nil,
            timeout_state: { current: scan[:timeout], min: MIN_ADAPTIVE_TIMEOUT_S },
            stop_state: init_stop_state(scan),
            retired_clients: [],
            target_shape: init_target_shape,
            extension_state: init_extension_state,
            dispatch_state: init_dispatch_state,
            concurrency_state: init_concurrency_state(scan),
            activity_state: init_activity_state(scan),
            adaptation_state: init_adaptation_state
          }
          runtime[:queue] = build_work_queue(scan, runtime)
          runtime
        end

        def init_target_shape
          {
            wildcard: false,
            redirect_cluster: false,
            extension_useful: nil
          }
        end

        def init_extension_state
          {
            enabled: false,
            reason: nil
          }
        end

        def init_dispatch_state
          {
            mode: 'threaded',
            http2_confirmed: false,
            fallback_reason: nil
          }
        end

        def init_concurrency_state(scan)
          max = thread_cap_for_mode(scan[:mode], scan[:options][:threads].to_i)
          {
            max: [max, 1].max,
            current: [max, 1].max,
            min: ADAPTIVE_CONCURRENCY_MIN.clamp(1, [max, 1].max),
            last_eval_count: 0
          }
        end

        def init_adaptation_state
          {
            last_eval_count: 0,
            last_eval_at_mono: Process.clock_gettime(Process::CLOCK_MONOTONIC),
            previous_totals: {
              errors: 0,
              timeout: 0,
              connection: 0,
              tls: 0,
              prioritized: 0,
              all_found: 0
            },
            pressure_streak: 0,
            low_yield_streak: 0,
            last_pressure_score: 0,
            last_window: {
              count: 0,
              error_ratio: 0.0,
              transport_ratio: 0.0,
              avg_rps: 0.0,
              prioritized_gain: 0,
              found_gain: 0
            }
          }
        end

        def init_activity_state(scan)
          timeout = scan[:timeout].to_f
          stall_timeout = [timeout * 10.0, MIN_STALL_TIMEOUT_S].max
          {
            last_activity_at_mono: Process.clock_gettime(Process::CLOCK_MONOTONIC),
            stall_timeout_s: stall_timeout.clamp(MIN_STALL_TIMEOUT_S, MAX_STALL_TIMEOUT_S),
            watchdog_active: false,
            watchdog_stop: false,
            watchdog_thread: nil
          }
        end

        def init_stats
          {
            success: 0,
            errors: 0,
            timeout_downshifts: 0,
            mode_downshifts: 0,
            pressure_events: 0,
            low_yield_events: 0,
            positive_statuses: Hash.new(0),
            confidence_levels: Hash.new(0),
            confidence_reasons: Hash.new(0),
            waf_sensitive_promotion_count: 0,
            error_kinds: Hash.new(0)
          }
        end

        def init_redirect_signals
          {
            counts: {
              cross_scope: 0,
              callback_like: 0,
              auth_flow: 0
            },
            examples: []
          }
        end

        def init_stop_state(scan)
          {
            stop: false,
            reason: nil,
            mode: scan[:mode],
            budgets: scan[:budgets],
            preflight: scan[:preflight],
            request_method: request_method_for_mode(scan[:mode]),
            request_headers: scan[:options][:request_headers],
            allow_redirects: scan[:options][:allow_redirects],
            client_closed: false
          }
        end

        def build_work_queue(source, runtime = nil)
          return LazyDirectoryQueue.new(source, runtime) if source.is_a?(Hash) && source[:url_plan]

          queue = Queue.new
          source.each { |url| queue << url }
          queue
        end

        def run_workers(scan, runtime)
          num_workers = [runtime[:concurrency_state][:max].to_i, 1].max
          prepare_runtime_client!(scan, runtime, num_workers)
          start_stall_watchdog!(runtime, scan)
          if batch_dispatch_candidate?(scan, runtime[:stop_state])
            runtime[:dispatch_state][:mode] = 'http2_probe'
            run_batch_dispatcher(scan, runtime, num_workers)
          else
            runtime[:dispatch_state][:mode] = 'threaded'
            run_threaded_workers(scan, runtime, num_workers)
          end
        ensure
          stop_stall_watchdog!(runtime) if runtime
          close_retired_clients!(runtime) if runtime
          close_client!(runtime[:stop_state], runtime[:client]) if runtime
        end

        def start_stall_watchdog!(runtime, scan)
          state = runtime[:activity_state]
          state[:watchdog_active] = true
          state[:watchdog_stop] = false
          state[:watchdog_thread] = Thread.new do
            loop do
              break if state[:watchdog_stop]
              break if run_stall_watchdog_iteration(runtime, scan, state)
            end
          end
        end

        def run_stall_watchdog_iteration(runtime, scan, state)
          sleep(STALL_WATCHDOG_INTERVAL_S)
          should_break = false
          runtime[:mutex].synchronize do
            should_break = true if runtime[:stop_state][:stop]
            next if should_break

            idle_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - state[:last_activity_at_mono].to_f
            next unless idle_s >= state[:stall_timeout_s].to_f

            mark_stall_stop!(runtime, scan, state, idle_s)
          end
          should_break
        end

        def mark_stall_stop!(runtime, scan, state, idle_s)
          runtime[:stop_state][:stop] = true
          runtime[:stop_state][:reason] ||= stall_stop_reason(idle_s, state[:stall_timeout_s].to_f)
          capture_stop_status_code_shape!(runtime)
          Log.write("[dirrec] Stall watchdog triggered: #{runtime[:stop_state][:reason]}")
          print_progress(runtime, scan, force: true)
        end

        def stop_stall_watchdog!(runtime)
          state = runtime[:activity_state]
          return unless state[:watchdog_active]

          state[:watchdog_stop] = true
          state[:watchdog_thread]&.join(0.2)
          state[:watchdog_active] = false
          state[:watchdog_thread] = nil
        end

        def touch_runtime_activity!(runtime)
          state = runtime[:activity_state]
          return unless state.is_a?(Hash)

          state[:last_activity_at_mono] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def stall_stop_reason(idle_s, budget_s)
          "inactivity budget hit (#{idle_s.round(2)}s/#{budget_s.round(2)}s)"
        end

        def close_retired_clients!(runtime)
          retired = runtime[:retired_clients].is_a?(Array) ? runtime[:retired_clients] : []
          current = runtime[:client]

          retired.each do |client|
            next unless client
            next if client.equal?(current)

            client.close if client.respond_to?(:close)
          rescue StandardError
            nil
          end
          retired.clear
        end

        def prepare_runtime_client!(scan, runtime, num_workers)
          runtime[:client] = build_bulk_client(scan, num_workers)
        end

        def build_bulk_client(scan, num_workers)
          Nokizaru::HTTPClient.for_bulk_requests(
            scan[:scan_target],
            timeout_s: scan[:timeout],
            headers: { 'User-Agent' => DEFAULT_UA },
            follow_redirects: follow_redirects_for_client(scan[:options][:allow_redirects],
                                                          scan[:options][:request_headers]),
            verify_ssl: scan[:options][:verify_ssl],
            max_concurrent: num_workers,
            retries: 0
          )
        end

        def follow_redirects_for_client(allow_redirects, request_headers)
          allow_redirects && Nokizaru::RequestHeaders.none?(request_headers)
        end

        def finalize_scan(scan, runtime)
          runtime[:stats][:elapsed] = Time.now - runtime[:start_time]
          print_progress(runtime, scan, force: true)
          dir_output(runtime: runtime, scan: scan)
          Log.write('[dirrec] Completed')
        end
      end
    end
  end
end
