# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Dispatch
        private

        def run_worker_loop(scan, runtime)
          error_streak = 0
          loop do
            url = pop_queue_url(runtime[:queue])
            break unless worker_active?(url, runtime[:stop_state])
            break unless reserve_request_slot!(runtime)

            begin
              error_streak = process_worker_url(scan, runtime, url, error_streak)
            ensure
              release_request_slot!(runtime)
            end
          end
        end

        def pop_queue_url(queue)
          queue.pop(true)
        rescue ThreadError
          nil
        end

        def worker_active?(url, stop_state)
          url && !stop_state[:stop] && !Nokizaru::InterruptState.interrupted?
        end

        def batch_dispatch_candidate?(scan, stop_state)
          return false if custom_request_headers?(stop_state) && stop_state[:allow_redirects]

          URI.parse(scan[:normalized_target].to_s).scheme == 'https'
        rescue StandardError
          false
        end

        def run_threaded_workers(scan, runtime, num_workers)
          workers = Array.new(num_workers) { Thread.new { run_worker_loop(scan, runtime) } }
          workers.each(&:join)
        end

        def run_batch_dispatcher(scan, runtime, num_workers)
          error_streak = 0
          http2_confirmed = false
          loop do
            urls = next_request_batch(runtime, limit: batch_limit(http2_confirmed, runtime))
            break if urls.empty?

            responses = request_batch_with_active_slots(scan, runtime, urls, error_streak)
            unless responses.is_a?(Array)
              error_streak = responses
              runtime[:dispatch_state][:fallback_reason] ||= 'batch_probe_error'
              break if fallback_to_threaded_workers?(scan, runtime, num_workers, http2_confirmed)

              next
            end

            if http2_batch_confirmed?(http2_confirmed, responses)
              mark_http2_batch_confirmed!(runtime)
              http2_confirmed = true
            end
            error_streak = process_batch_responses(scan, runtime, urls, responses, error_streak)
            break if runtime[:stop_state][:stop] || Nokizaru::InterruptState.interrupted?
            break if fallback_to_threaded_workers?(scan, runtime, num_workers, http2_confirmed)
          end
        end

        def http2_batch_confirmed?(http2_confirmed, responses)
          !http2_confirmed && http2_batch_responses?(responses)
        end

        def mark_http2_batch_confirmed!(runtime)
          runtime[:dispatch_state][:http2_confirmed] = true
          runtime[:dispatch_state][:mode] = 'http2_batch'
        end

        def fallback_to_threaded_workers?(scan, runtime, num_workers, http2_confirmed)
          return false if http2_confirmed

          runtime[:dispatch_state][:mode] = 'threaded_fallback'
          runtime[:dispatch_state][:fallback_reason] ||= 'http2_not_confirmed'
          run_threaded_workers(scan, runtime, num_workers)
          true
        end

        def batch_limit(http2_confirmed, runtime)
          return nil if http2_confirmed

          [runtime.dig(:concurrency_state, :current).to_i, 2].min
        end

        def next_request_batch(runtime, limit: nil)
          batch = []
          runtime[:mutex].synchronize do
            batch_limit = [limit || runtime.dig(:concurrency_state, :current).to_i, 1].max
            reserve_batch_urls!(runtime, batch, batch_limit)
            touch_runtime_activity!(runtime) if batch.any?
          end
          batch
        end

        def reserve_batch_urls!(runtime, batch, batch_limit)
          while batch.length < batch_limit
            break if should_stop_now?(runtime[:issued], runtime[:start_time], runtime[:stop_state])

            url = pop_queue_url(runtime[:queue])
            break unless worker_active?(url, runtime[:stop_state])

            runtime[:issued] += 1
            batch << url
          end
        end

        def request_batch_with_active_slots(scan, runtime, urls, error_streak)
          mark_batch_requests_active!(runtime, urls.length)
          responses = safe_batch_http_results(scan, runtime, urls, error_streak)
          return responses unless responses.is_a?(Array)

          release_batch_request_slots!(runtime, urls.length)
          responses
        end

        def safe_batch_http_results(scan, runtime, urls, error_streak)
          batch_http_results(runtime, urls)
        rescue StandardError => e
          release_batch_request_slots!(runtime, urls.length)
          process_batch_exception(scan, runtime, urls, e, error_streak)
        end

        def mark_batch_requests_active!(runtime, count)
          runtime[:mutex].synchronize do
            runtime[:active_requests] += count.to_i
            touch_runtime_activity!(runtime)
          end
        end

        def release_batch_request_slots!(runtime, count)
          runtime[:mutex].synchronize do
            runtime[:active_requests] = [runtime[:active_requests].to_i - count.to_i, 0].max
          end
        end

        def http2_batch_responses?(responses)
          responses.any? do |result|
            response = result.respond_to?(:response) ? result.response : nil
            response.respond_to?(:version) && response.version.to_s.start_with?('2')
          end
        end

        def process_batch_responses(scan, runtime, urls, responses, error_streak)
          urls.each_with_index do |url, index|
            http_result = responses[index] || worker_http_result(runtime, url)
            error_streak = process_batch_response(scan, runtime, url, http_result, error_streak)
            break if runtime[:stop_state][:stop] || Nokizaru::InterruptState.interrupted?
          end
          error_streak
        end

        def process_batch_response(scan, runtime, url, http_result, error_streak)
          return process_worker_error(scan, runtime, http_result, error_streak + 1) unless http_result.success?

          process_worker_success(scan, runtime, url, http_result)
          0
        rescue StandardError => e
          handle_worker_exception(scan, runtime, url, e, error_streak)
        end

        def process_batch_exception(scan, runtime, urls, error, error_streak)
          urls.each do |url|
            process_worker_exception(scan, runtime, url, error)
            error_streak += 1
          end
          sleep(error_backoff_s(error_streak, runtime[:stop_state][:mode]))
          error_streak
        end

        # Reserve one request slot before dispatch so request budgets remain strict under concurrency
        def reserve_request_slot!(runtime)
          runtime[:mutex].synchronize do
            loop do
              return false if should_stop_now?(runtime[:issued], runtime[:start_time], runtime[:stop_state])

              if runtime[:active_requests].to_i >= runtime.dig(:concurrency_state, :current).to_i
                runtime[:slot_cv].wait(runtime[:mutex], 0.2)
                next
              end

              runtime[:issued] += 1
              runtime[:active_requests] += 1
              touch_runtime_activity!(runtime)
              return true
            end
          end
        end

        def release_request_slot!(runtime)
          runtime[:mutex].synchronize do
            runtime[:active_requests] = [runtime[:active_requests].to_i - 1, 0].max
            runtime[:slot_cv].signal
          end
        end

        def process_worker_url(scan, runtime, url, error_streak)
          http_result = worker_http_result(runtime, url)
          return process_worker_error(scan, runtime, http_result, error_streak + 1) unless http_result.success?

          process_worker_success(scan, runtime, url, http_result)
          0
        rescue StandardError => e
          handle_worker_exception(scan, runtime, url, e, error_streak)
        end

        def worker_http_result(runtime, url)
          raw_resp = request_url(runtime[:client], url, runtime[:stop_state])
          HttpResult.new(raw_resp)
        end

        def batch_http_results(runtime, urls)
          request_urls(runtime[:client], urls, runtime[:stop_state]).map { |response| HttpResult.new(response) }
        end

        def handle_worker_exception(scan, runtime, url, error, error_streak)
          process_worker_exception(scan, runtime, url, error)
          next_streak = error_streak + 1
          sleep(error_backoff_s(next_streak, runtime[:stop_state][:mode]))
          next_streak
        end

        def process_worker_success(scan, runtime, url, http_result)
          sample = response_sample(http_result, request_url: url)
          decision_input = nil
          runtime[:mutex].synchronize do
            decision_input = process_synchronized_success(scan, runtime, url, http_result, sample)
          end
          return unless decision_input

          decision = confidence_decision_for_success(scan, url, decision_input)
          runtime[:mutex].synchronize do
            track_confidence_finding(scan, runtime, url, decision_input[:status], decision)
          end
        end

        def process_synchronized_success(scan, runtime, url, http_result, sample)
          increment_count!(runtime[:stats], runtime)
          handle_runtime_adaptation!(scan, runtime)
          decision_input = handle_success_status(scan, runtime, url, http_result, sample)
          print_progress(runtime, scan) if (runtime[:count] % PROGRESS_EVERY).zero?
          decision_input
        end

        def confidence_decision_for_success(scan, url, input)
          decision = finding_confidence(url, input[:status], input[:sample], input[:baseline], scan[:normalized_target])
          apply_waf_confidence_adjustment(
            decision,
            url,
            input[:confidence_context]
          )
        end

        def increment_count!(stats, runtime)
          stats[:success] += 1
          runtime[:count] += 1
          touch_runtime_activity!(runtime)
        end
      end
    end
  end
end
