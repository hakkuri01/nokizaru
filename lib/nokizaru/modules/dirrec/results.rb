# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Results
        private

        def dir_output(runtime:, scan:)
          stats = runtime[:stats]
          elapsed = stats[:elapsed] || 1
          rps = ((stats[:success] + stats[:errors]) / elapsed).round(1)
          stop_meta = dir_stop_meta(runtime[:stop_state])
          decorate_dir_output_stats!(runtime, stats)
          result = dir_result(scan, runtime, stats, stop_meta, elapsed, rps)

          print_dir_summary(rps, runtime, stop_meta[:display_reason], runtime[:redirect_signals])
          store_dir_result(scan, result)
        end

        def decorate_dir_output_stats!(runtime, stats)
          stats[:confidence_context] = confidence_context_snapshot(runtime)
          stats[:adaptation_state] = runtime[:adaptation_state]
          stats[:extension_phase_enabled] = runtime.dig(:extension_state, :enabled) == true
          stats[:extension_phase_reason] = runtime.dig(:extension_state, :reason)
          decorate_dir_dispatch_stats!(runtime, stats)
          stats[:adaptive_concurrency] = runtime.dig(:concurrency_state, :current).to_i
          stats[:time_to_first_actionable_s] = time_to_first_actionable(runtime)
          stats[:requests_to_first_actionable] = runtime[:first_actionable_count].to_i
        end

        def decorate_dir_dispatch_stats!(runtime, stats)
          stats[:dispatch_mode] = runtime.dig(:dispatch_state, :mode).to_s
          stats[:dispatch_http2_confirmed] = runtime.dig(:dispatch_state, :http2_confirmed) == true
          stats[:dispatch_fallback_reason] = runtime.dig(:dispatch_state, :fallback_reason).to_s
          stats[:stop_status_code_shape] = runtime[:stop_status_code_shape].to_s
        end

        def dir_stop_meta(stop_state)
          state = stop_state || {}
          {
            mode: state[:mode].to_s,
            reason: state[:reason].to_s,
            display_reason: display_stop_reason(state[:reason]),
            preflight: state[:preflight],
            budgets: state[:budgets].is_a?(Hash) ? state[:budgets] : {}
          }
        end

        def time_to_first_actionable(runtime)
          first = runtime[:first_actionable_at]
          return 0.0 unless first

          first - runtime[:start_time]
        end

        def dir_result(scan, runtime, stats, stop_meta, elapsed, rps)
          high_signal_found = rank_high_signal_paths(runtime[:signal_responses], scan[:normalized_target])
          found = runtime[:all_found].uniq
          prioritized_found = runtime[:found].uniq
          low_confidence_found = runtime[:low_confidence_found].uniq
          {
            'target' => {
              'original' => scan[:options][:target],
              'effective' => scan[:scan_target],
              'reanchored' => scan[:anchor][:reanchor],
              'reason' => scan[:anchor][:reason]
            },
            'found' => found,
            'prioritized_found' => prioritized_found,
            'stdout_found' => runtime[:stdout_found].uniq,
            'confirmed_found' => runtime[:confirmed_found].uniq,
            'low_confidence_found' => low_confidence_found,
            'high_signal_found' => high_signal_found,
            'by_status' => grouped_response_statuses(runtime[:responses]),
            'stats' => dir_stats(stats, stop_meta, elapsed, rps)
          }
        end

        def rank_high_signal_paths(responses, normalized_target)
          Array(responses)
            .map { |url, status| [url.to_s, score_path_signal(url, status, normalized_target)] }
            .select { |(_, score)| score.positive? }
            .sort_by { |(url, score)| [-score, url.length] }
            .first(200)
            .map(&:first)
            .uniq
        end

        def score_path_signal(url, status, normalized_target)
          path = URI.parse(url).path.to_s.downcase
          target_path = URI.parse(normalized_target).path.to_s.downcase
          return 0 if path.empty? || path == '/' || path == target_path

          status_signal_score(status.to_i) + path_signal_score(path)
        rescue StandardError
          0
        end

        def status_signal_score(code)
          return 4 if [401, 403].include?(code)
          return 3 if [200, 500].include?(code)
          return 1 if [301, 302, 303, 307, 308].include?(code)

          0
        end

        def path_signal_score(path)
          score = 0
          score += 4 if high_signal_path?(path)
          score += 1 if path.count('/') >= 2
          score -= 3 if low_information_segment?(first_path_segment(path))
          score
        end

        def first_path_segment(path)
          path.to_s.split('/').reject(&:empty?).first.to_s.downcase
        end

        def high_signal_path_tokens
          @high_signal_path_tokens ||= HIGH_SIGNAL_PATHS.map { |seed| seed.delete_prefix('/').downcase }
        end

        def high_signal_path?(path)
          HIGH_SIGNAL_PATHS.any? { |seed| path_matches_seed?(path, seed.downcase) }
        end

        def path_matches_seed?(path, seed)
          path == seed || path.start_with?("#{seed}/")
        end

        def low_information_segment?(segment)
          segment.match?(/\A[a-z]{1,10}\z/) && high_signal_path_tokens.none? { |token| token.include?(segment) }
        end

        def grouped_response_statuses(responses)
          grouped = responses.group_by { |(_, status)| status.to_s }
          grouped.transform_values { |rows| rows.map(&:first) }
        end

        def dir_stats(stats, stop_meta, elapsed, rps)
          context = stats[:confidence_context] || {}
          dir_runtime_stats(stats, stop_meta, elapsed, rps)
            .merge(dir_confidence_stats(stats))
            .merge(dir_context_stats(context))
        end

        def dir_runtime_stats(stats, stop_meta, elapsed, rps)
          adaptation = stats[:adaptation_state].is_a?(Hash) ? stats[:adaptation_state] : {}
          last_window = adaptation[:last_window].is_a?(Hash) ? adaptation[:last_window] : {}
          dir_runtime_base_stats(stats, stop_meta, elapsed, rps)
            .merge(dir_runtime_pressure_stats(adaptation, last_window))
        end

        def dir_runtime_base_stats(stats, stop_meta, elapsed, rps)
          dir_stop_stats(stop_meta).merge(
            'total_requests' => stats[:success] + stats[:errors],
            'successful' => stats[:success],
            'errors' => stats[:errors],
            'error_breakdown' => stats[:error_kinds].to_h,
            'timeout_downshifts' => stats[:timeout_downshifts].to_i,
            'mode_downshifts' => stats[:mode_downshifts].to_i,
            'pressure_events' => stats[:pressure_events].to_i,
            'low_yield_events' => stats[:low_yield_events].to_i,
            'elapsed_seconds' => elapsed.round(2),
            'requests_per_second' => rps
          ).merge(dir_runtime_adaptive_stats(stats))
        end

        def dir_stop_stats(stop_meta)
          technical_reason = stop_meta[:reason].to_s
          display_reason = stop_meta[:display_reason].to_s
          {
            'mode' => stop_meta[:mode],
            'stop_reason' => technical_reason.empty? ? nil : technical_reason,
            'stop_reason_display' => display_reason.empty? ? nil : display_reason,
            'budget_seconds' => stop_meta[:budgets][:budget_s],
            'max_requests' => stop_meta[:budgets][:max_requests],
            'preflight' => stop_meta[:preflight]
          }
        end

        def dir_runtime_adaptive_stats(stats)
          {
            'extension_phase_enabled' => stats[:extension_phase_enabled],
            'extension_phase_reason' => stats[:extension_phase_reason],
            'dispatch_mode' => stats[:dispatch_mode],
            'dispatch_http2_confirmed' => stats[:dispatch_http2_confirmed],
            'dispatch_fallback_reason' => stats[:dispatch_fallback_reason],
            'stop_status_code_shape' => empty_string_as_nil(stats[:stop_status_code_shape]),
            'adaptive_concurrency' => stats[:adaptive_concurrency]
          }.merge(dir_runtime_first_actionable_stats(stats))
        end

        def empty_string_as_nil(value)
          text = value.to_s
          text.empty? ? nil : text
        end

        def dir_runtime_first_actionable_stats(stats)
          {
            'time_to_first_actionable_s' => stats[:time_to_first_actionable_s].to_f.round(4),
            'requests_to_first_actionable' => stats[:requests_to_first_actionable].to_i
          }
        end

        def dir_runtime_pressure_stats(adaptation, last_window)
          {
            'pressure_streak' => adaptation[:pressure_streak].to_i,
            'low_yield_streak' => adaptation[:low_yield_streak].to_i,
            'pressure_score' => adaptation[:last_pressure_score].to_i,
            'pressure_window_avg_rps' => last_window[:avg_rps].to_f.round(2),
            'pressure_window_error_ratio' => last_window[:error_ratio].to_f.round(4),
            'pressure_window_transport_ratio' => last_window[:transport_ratio].to_f.round(4),
            'pressure_window_prioritized_gain' => last_window[:prioritized_gain].to_i
          }
        end

        def dir_confidence_stats(stats)
          {
            'confidence_levels' => stats[:confidence_levels].to_h,
            'confidence_reasons' => stats[:confidence_reasons].to_h,
            'waf_sensitive_promotion_count' => stats[:waf_sensitive_promotion_count].to_i
          }
        end

        def dir_context_stats(context)
          {
            'waf_likelihood_score' => context[:waf_likelihood_score].to_f.round(4),
            'waf_score_confidence' => context[:waf_score_confidence].to_s,
            'redirect_cluster_dominance_ratio' => context[:redirect_cluster_dominance_ratio].to_f.round(4),
            'soft_404_dominance_ratio' => context[:soft_404_dominance_ratio].to_f.round(4),
            'sensitive_status_total' => context[:sensitive_status_total].to_i,
            'sensitive_status_homogeneity_ratio' => context[:sensitive_status_homogeneity_ratio].to_f.round(4),
            'sensitive_status_fingerprint_uniqueness_ratio' =>
              context[:sensitive_status_fingerprint_uniqueness_ratio].to_f.round(4),
            'context_sources_used' => Array(context[:context_sources_used]),
            'context_sources_missing' => Array(context[:context_sources_missing])
          }
        end
      end
    end
  end
end
