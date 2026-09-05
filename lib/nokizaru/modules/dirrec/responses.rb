# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Responses
        private

        def handle_success_status(scan, runtime, url, http_result, sample)
          status = http_result.status.to_i
          runtime[:responses] << [url, status]
          track_raw_finding(runtime[:all_found], scan[:scan_target], url, status)
          runtime[:signal_responses] << [url, status] if SOFT_404_SAMPLE_STATUSES.include?(status)
          track_redirect_signal(runtime[:redirect_signals], url, http_result, status)
          return nil unless FINDING_CANDIDATE_STATUSES.include?(status)

          baseline = update_soft_404_runtime_baseline!(runtime, sample)
          update_confidence_context!(runtime, status, sample, baseline)
          {
            status: status,
            sample: sample,
            baseline: baseline,
            confidence_context: confidence_context_snapshot(runtime)
          }
        end

        def track_raw_finding(all_found, target, url, status)
          return if url == "#{target}/"
          return unless FINDING_CANDIDATE_STATUSES.include?(status)

          all_found << url
        end

        def update_soft_404_runtime_baseline!(runtime, sample)
          state = runtime[:soft_404_state]
          baseline = runtime[:soft_404_baseline]
          learning = runtime[:soft_404_learning]
          return baseline if sample.nil?
          return baseline unless soft_404_active?(state, baseline)

          record_soft_404_sample!(state)
          runtime[:soft_404_baseline] = learn_soft_404_baseline(sample, baseline, learning)
          disable_soft_404_if_unstable!(state, runtime[:soft_404_baseline], learning)
          runtime[:soft_404_baseline]
        end

        def track_confidence_finding(scan, runtime, url, status, decision)
          confidence = decision[:level].to_sym
          reason = decision[:reason].to_s
          update_confidence_stats!(runtime[:stats], confidence, reason, status)
          assign_confidence_bucket(runtime, url, confidence)
          print_finding(scan, runtime, url, status) unless confidence == :low
        end

        def update_confidence_stats!(stats, confidence, reason, status)
          stats[:confidence_levels][confidence.to_s] += 1
          stats[:confidence_reasons][reason] += 1 unless reason.empty?
          stats[:waf_sensitive_promotion_count] += 1 if confidence != :low && sensitive_status_reason?(reason)
          stats[:positive_statuses][status] += 1
        end

        def assign_confidence_bucket(runtime, url, confidence)
          if confidence == :confirmed
            runtime[:confirmed_found] << url
            runtime[:found] << url
            track_first_actionable!(runtime)
          elsif confidence == :likely
            runtime[:found] << url
            track_first_actionable!(runtime)
          else
            runtime[:low_confidence_found] << url
          end
        end

        def track_first_actionable!(runtime)
          return if runtime[:first_actionable_at]

          runtime[:first_actionable_at] = Time.now
          runtime[:first_actionable_count] = runtime[:count].to_i
        end

        def track_redirect_signal(redirect_signals, request_url, http_result, status)
          return unless redirect_status?(status)

          signal_type = redirect_signal_type(request_url, http_result)
          return unless signal_type

          redirect_signals[:counts][signal_type] += 1
          push_redirect_example(redirect_signals[:examples], signal_type, status, request_url, http_result)
        end

        def process_worker_error(scan, runtime, http_result, error_streak)
          error_kind = classify_error(http_result)
          runtime[:mutex].synchronize do
            record_worker_error!(runtime, http_result, error_kind)
            maybe_stop!(runtime)
            adapt_timeout_if_needed!(scan, runtime)
            handle_runtime_adaptation!(scan, runtime)
            print_progress(runtime, scan) if (runtime[:count] % PROGRESS_EVERY).zero?
          end

          sleep(error_backoff_s(error_streak, runtime[:stop_state][:mode]))
          error_streak
        end

        def record_worker_error!(runtime, http_result, error_kind)
          runtime[:stats][:errors] += 1
          runtime[:stats][:error_kinds][error_kind] += 1
          runtime[:count] += 1
          touch_runtime_activity!(runtime)
          log_error(http_result, runtime[:stats][:errors])
        end

        def process_worker_exception(scan, runtime, url, error)
          runtime[:mutex].synchronize do
            runtime[:stats][:errors] += 1
            runtime[:stats][:error_kinds] ||= Hash.new(0)
            runtime[:stats][:error_kinds]['other'] += 1
            runtime[:count] += 1
            touch_runtime_activity!(runtime)
            Log.write("[dirrec] Exception for #{url}: #{error.class}") if runtime[:stats][:errors] <= 5
            handle_runtime_adaptation!(scan, runtime)
            print_progress(runtime, scan) if (runtime[:count] % PROGRESS_EVERY).zero?
          end
        end
      end
    end
  end
end
