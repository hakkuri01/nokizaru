# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Adaptation
        private

        def handle_runtime_adaptation!(scan, runtime)
          return unless runtime[:stop_state].is_a?(Hash)
          return unless runtime[:timeout_state].is_a?(Hash)

          maybe_stop!(runtime)
          update_pressure_window!(runtime)
          update_target_shape!(runtime)
          update_extension_state!(runtime)
          update_dynamic_concurrency!(runtime)
          apply_marginal_value_stop!(runtime)
          result = apply_mode_downgrade!(runtime[:count], runtime[:stats], runtime[:stop_state],
                                         runtime[:timeout_state], runtime: runtime)
          return unless result == :downgraded

          apply_mode_rebuild!(scan, runtime)
        end

        def apply_mode_rebuild!(scan, runtime)
          previous_client = runtime[:client]
          rebuild = rebuild_client(client_config(scan, runtime))
          runtime[:client], runtime[:timeout_state] = rebuild
          track_retired_runtime_client!(runtime, previous_client)
          runtime[:stats][:mode_downshifts] = runtime[:stats][:mode_downshifts].to_i + 1
        end

        def track_retired_runtime_client!(runtime, previous_client)
          return unless previous_client
          return if runtime[:client].equal?(previous_client)

          runtime[:retired_clients] << previous_client
        end

        def update_pressure_window!(runtime)
          state = runtime[:adaptation_state]
          return unless state.is_a?(Hash)

          window = pressure_window_snapshot(runtime, state)
          return unless window

          state[:last_window] = window
          state[:last_pressure_score] = pressure_window_score(runtime, window)
          update_pressure_streak!(runtime, state, window)
          update_low_yield_streak!(runtime, state, window)
          refresh_pressure_window_snapshot!(runtime, state)
        end

        def update_pressure_streak!(runtime, state, window)
          active = pressure_window_active?(window, state[:last_pressure_score])
          state[:pressure_streak] = active ? state[:pressure_streak].to_i + 1 : 0
          runtime[:stats][:pressure_events] += 1 if state[:last_pressure_score].to_i.positive?
        end

        def update_low_yield_streak!(runtime, state, window)
          if low_yield_window?(window)
            state[:low_yield_streak] = state[:low_yield_streak].to_i + 1
            runtime[:stats][:low_yield_events] += 1
          else
            state[:low_yield_streak] = 0
          end
        end

        def pressure_window_snapshot(runtime, state)
          count_delta = runtime[:count].to_i - state[:last_eval_count].to_i
          return nil if count_delta < PRESSURE_WINDOW_REQUESTS

          now_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          elapsed = now_mono - state[:last_eval_at_mono].to_f
          return nil if elapsed < PRESSURE_MIN_WINDOW_SECONDS

          previous = state[:previous_totals].is_a?(Hash) ? state[:previous_totals] : {}
          totals = pressure_totals(runtime)
          deltas = pressure_deltas(previous, totals)
          {
            count: count_delta,
            error_count: deltas[:errors],
            timeout_count: deltas[:timeout],
            connection_count: deltas[:connection],
            tls_count: deltas[:tls],
            prioritized_gain: deltas[:prioritized],
            found_gain: deltas[:all_found],
            avg_rps: count_delta.fdiv(elapsed)
          }
        end

        def pressure_totals(runtime)
          {
            errors: runtime[:stats][:errors].to_i,
            timeout: runtime[:stats][:error_kinds]['timeout'].to_i,
            connection: runtime[:stats][:error_kinds]['connection'].to_i,
            tls: runtime[:stats][:error_kinds]['tls'].to_i,
            prioritized: runtime[:found].length,
            all_found: runtime[:all_found].length
          }
        end

        def pressure_deltas(previous, totals)
          {
            errors: delta_since(previous, totals, :errors),
            timeout: delta_since(previous, totals, :timeout),
            connection: delta_since(previous, totals, :connection),
            tls: delta_since(previous, totals, :tls),
            prioritized: delta_since(previous, totals, :prioritized),
            all_found: delta_since(previous, totals, :all_found)
          }
        end

        def delta_since(previous, totals, key)
          [totals[key].to_i - previous.fetch(key, 0).to_i, 0].max
        end

        def pressure_window_score(runtime, window)
          error_ratio = window[:error_count].fdiv(window[:count].to_f)
          transport_count = window[:timeout_count].to_i + window[:connection_count].to_i + window[:tls_count].to_i
          transport_ratio = transport_count.fdiv(window[:count].to_f)
          context = confidence_context_snapshot(runtime)
          score = pressure_ratio_score(window, error_ratio, transport_ratio)
          score += pressure_context_score(context)

          window[:error_ratio] = error_ratio.round(4)
          window[:transport_ratio] = transport_ratio.round(4)
          score
        end

        def pressure_ratio_score(window, error_ratio, transport_ratio)
          score = 0
          score += 1 if error_ratio >= PRESSURE_WINDOW_ERROR_RATIO
          score += 1 if transport_ratio >= PRESSURE_WINDOW_TRANSPORT_RATIO
          score += 1 if window[:avg_rps].to_f < PRESSURE_WINDOW_LOW_RPS && transport_ratio >= 0.1
          score += 1 if low_yield_window?(window) && transport_ratio >= 0.12
          score
        end

        def pressure_context_score(context)
          score = 0
          score += 1 if context[:waf_likelihood_score].to_f >= PRESSURE_SCORE_WAF_HINT
          score += 1 if context[:redirect_cluster_dominance_ratio].to_f >= PRESSURE_SCORE_REDIRECT_HINT
          score
        end

        def low_yield_window?(window)
          window[:found_gain].to_i >= 80 && window[:prioritized_gain].to_i <= PRESSURE_WINDOW_LOW_YIELD_GAIN
        end

        def pressure_window_active?(window, score)
          return true if score.to_i >= 2

          window[:error_ratio].to_f >= 0.25 && window[:transport_ratio].to_f >= 0.15
        end

        def refresh_pressure_window_snapshot!(runtime, state)
          state[:last_eval_count] = runtime[:count].to_i
          state[:last_eval_at_mono] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          state[:previous_totals] = pressure_totals(runtime)
        end

        def update_target_shape!(runtime)
          shape = runtime[:target_shape]
          return unless shape.is_a?(Hash)

          context = confidence_context_snapshot(runtime)
          shape[:wildcard] = context[:soft_404_dominance_ratio].to_f >= MARGINAL_VALUE_DOMINANCE_RATIO
          shape[:redirect_cluster] = context[:redirect_cluster_dominance_ratio].to_f >= MARGINAL_VALUE_DOMINANCE_RATIO
          shape[:extension_useful] = true if runtime[:found].any? &&
                                             runtime[:count].to_i >= EXTENSION_SIGNAL_MIN_REQUESTS
        end

        def update_extension_state!(runtime)
          state = runtime[:extension_state]
          return unless state.is_a?(Hash)
          return if state[:enabled]

          allowed, reason = extension_phase_decision(runtime)
          return unless allowed

          state[:enabled] = true
          state[:reason] = reason
        end

        def extension_phase_decision(runtime)
          shape = runtime[:target_shape].is_a?(Hash) ? runtime[:target_shape] : {}
          return [true, 'useful extension phase'] if shape[:extension_useful] == true

          count = runtime[:count].to_i
          return [false, 'waiting for base-path signal'] if count < EXTENSION_SIGNAL_MIN_REQUESTS
          return [true, 'actionable base-path signal'] if runtime[:found].any?

          context = confidence_context_snapshot(runtime)
          low_ratio = low_confidence_ratio(runtime)
          dominant = context[:soft_404_dominance_ratio].to_f >= MARGINAL_VALUE_DOMINANCE_RATIO ||
                     context[:redirect_cluster_dominance_ratio].to_f >= MARGINAL_VALUE_DOMINANCE_RATIO
          if dominant || low_ratio >= EXTENSION_SIGNAL_MAX_LOW_INFO_RATIO
            return [false, 'dominant low-information target shape']
          end

          [runtime[:all_found].any?, 'raw base-path signal']
        end

        def low_confidence_ratio(runtime)
          total = runtime[:all_found].length
          return 0.0 unless total.positive?

          runtime[:low_confidence_found].length.fdiv(total)
        end

        def update_dynamic_concurrency!(runtime)
          state = runtime[:concurrency_state]
          return unless state.is_a?(Hash)
          return unless dynamic_concurrency_eval_due?(runtime, state)

          window = runtime.dig(:adaptation_state, :last_window)
          return unless window.is_a?(Hash)

          state[:last_eval_count] = runtime[:count].to_i
          if bad_concurrency_window?(window)
            state[:current] = [state[:current].to_i / 2, state[:min].to_i].max
          elsif healthy_concurrency_window?(window, runtime)
            state[:current] = [state[:current].to_i + 1, state[:max].to_i].min
          end
        end

        def dynamic_concurrency_eval_due?(runtime, state)
          (runtime[:count].to_i - state[:last_eval_count].to_i) >= ADAPTIVE_CONCURRENCY_WINDOW
        end

        def bad_concurrency_window?(window)
          window[:error_ratio].to_f >= ADAPTIVE_CONCURRENCY_BAD_ERROR_RATIO ||
            window[:transport_ratio].to_f >= PRESSURE_WINDOW_TRANSPORT_RATIO
        end

        def healthy_concurrency_window?(window, runtime)
          return false unless runtime[:found].any? || runtime[:all_found].any?

          window[:error_ratio].to_f <= ADAPTIVE_CONCURRENCY_RECOVER_ERROR_RATIO &&
            window[:transport_ratio].to_f <= ADAPTIVE_CONCURRENCY_RECOVER_ERROR_RATIO
        end

        def apply_marginal_value_stop!(runtime)
          return if runtime[:stop_state][:stop]
          return unless marginal_value_stop?(runtime)

          runtime[:stop_state][:stop] = true
          runtime[:stop_state][:reason] ||= marginal_value_stop_reason(runtime)
          capture_stop_status_code_shape!(runtime)
        end

        def capture_stop_status_code_shape!(runtime)
          return unless runtime.is_a?(Hash)
          return unless runtime[:stop_status_code_shape].to_s.empty?

          shape = status_code_shape_summary(runtime[:responses])
          runtime[:stop_status_code_shape] = shape unless shape.empty?
        end

        def status_code_shape_summary(responses)
          statuses = Array(responses).filter_map do |(_url, status)|
            code = status.to_i
            code.positive? ? code : nil
          end
          return '' if statuses.empty?

          total = statuses.length
          counts = statuses.tally
          counts.sort_by { |status, count| [-count, status] }
                .map { |status, count| status_code_shape_part(status, count, total) }
                .join(', ')
        end

        def status_code_shape_part(status, count, total)
          percent = (count.to_f / total * 100.0).round(1)
          "#{status}=#{count}/#{total} (#{percent}%)"
        end

        def marginal_value_stop?(runtime)
          return false if runtime[:count].to_i < MARGINAL_VALUE_MIN_REQUESTS

          window = runtime.dig(:adaptation_state, :last_window)
          return false unless window.is_a?(Hash)
          return false if window[:prioritized_gain].to_i > MARGINAL_VALUE_LOW_GAIN

          shape = runtime[:target_shape].is_a?(Hash) ? runtime[:target_shape] : {}
          (shape[:wildcard] || shape[:redirect_cluster]) && low_confidence_ratio(runtime) >= 0.75
        end

        def marginal_value_stop_reason(runtime)
          shape = runtime[:target_shape].is_a?(Hash) ? runtime[:target_shape] : {}
          'marginal directory value collapsed under dominant target shape ' \
            "(wildcard=#{shape[:wildcard]}, redirect_cluster=#{shape[:redirect_cluster]}, " \
            "low_confidence_ratio=#{low_confidence_ratio(runtime).round(2)})"
        end

        def display_stop_reason(reason)
          value = reason.to_s.strip
          return '' if value.empty?
          return 'Uniform redirects or soft-404s detected' if value.start_with?('marginal directory value')
          if value.start_with?('sustained hostile transport')
            return 'Hostile transport failures limited reliable checks'
          end
          return 'Hostile pressure with low reliable yield' if value.start_with?('sustained hostile pressure')
          return 'Request limit reached' if value.start_with?('request budget hit')
          return 'Time limit reached' if value.start_with?('time budget hit')
          return 'Responses stalled' if value.start_with?('inactivity budget hit')

          value
        end
      end
    end
  end
end
