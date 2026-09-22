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
          reconciled = reconcile_candidate_findings(scan, runtime)
          apply_reconciled_confidence_stats!(stats, reconciled[:entries])
          apply_reconciled_first_actionable!(runtime, reconciled[:entries])
          apply_reconciled_runtime_buckets!(runtime, reconciled)
          decorate_dir_output_stats!(runtime, stats)
          result = dir_result(scan, runtime, stats, stop_meta, { elapsed: elapsed, rps: rps }, reconciled)

          print_progress(runtime, scan, force: true)
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

        def dir_result(scan, runtime, stats, stop_meta, timing,
                       reconciled = reconcile_candidate_findings(scan, runtime))
          found = runtime[:all_found].uniq
          prioritized_found = reconciled[:prioritized]
          low_confidence_found = reconciled[:low]
          high_signal_found = rank_high_signal_paths(
            runtime[:signal_responses], scan[:normalized_target], prioritized_found.to_set
          )
          {
            'target' => {
              'original' => scan[:options][:target],
              'effective' => scan[:scan_target],
              'reanchored' => scan[:anchor][:reanchor],
              'reason' => scan[:anchor][:reason]
            },
            'found' => found,
            'prioritized_found' => prioritized_found,
            'stdout_found' => Array(runtime[:stdout_found]).uniq,
            'confirmed_found' => reconciled[:confirmed],
            'low_confidence_found' => low_confidence_found,
            'high_signal_found' => high_signal_found,
            'by_status' => grouped_response_statuses(runtime[:responses]),
            'stats' => dir_stats(stats, stop_meta, timing[:elapsed], timing[:rps])
          }
        end

        def reconcile_candidate_findings(scan, runtime)
          observations = Array(runtime[:candidate_observations])
          return existing_confidence_findings(runtime) if observations.empty?

          context = confidence_context_snapshot(runtime)
          crawler_paths = normalized_crawler_paths(scan)
          entries = observations.map do |observation|
            reconciled_candidate(scan, runtime, observation, context, crawler_paths)
          end
          demote_homogeneous_guesses!(entries, runtime)
          {
            entries: entries,
            prioritized: entries.filter_map { |entry| entry[:url] unless entry[:decision][:level] == :low }.uniq,
            confirmed: entries.filter_map { |entry| entry[:url] if entry[:decision][:level] == :confirmed }.uniq,
            low: entries.filter_map { |entry| entry[:url] if entry[:decision][:level] == :low }.uniq
          }
        end

        def existing_confidence_findings(runtime)
          {
            entries: [],
            prioritized: Array(runtime[:found]).uniq,
            confirmed: Array(runtime[:confirmed_found]).uniq,
            low: Array(runtime[:low_confidence_found]).uniq
          }
        end

        def reconciled_candidate(scan, runtime, observation, context, crawler_paths)
          decision = finding_confidence(
            observation[:url], observation[:status], observation[:sample], runtime[:soft_404_baseline],
            scan[:normalized_target]
          )
          {
            url: observation[:url],
            status: observation[:status].to_i,
            sample: observation[:sample],
            observed_count: observation[:observed_count],
            observed_at: observation[:observed_at],
            crawler: crawler_corroborated?(scan, observation[:url], crawler_paths),
            decision: apply_waf_confidence_adjustment(decision, observation[:url], context)
          }
        end

        def normalized_crawler_paths(scan)
          Array(scan.dig(:url_plan, :crawler_paths)).to_set do |path|
            normalize_pattern_path(canonical_corroboration_path(path))
          end
        end

        def crawler_corroborated?(scan, url, crawler_paths)
          path = canonical_corroboration_path(url)
          target_path = canonical_corroboration_path(scan[:normalized_target]).chomp('/')
          relative = path
          relative = '/' if !target_path.empty? && path == target_path
          relative = path.delete_prefix(target_path) if !target_path.empty? && path.start_with?("#{target_path}/")
          crawler_paths.include?(normalize_pattern_path(relative))
        end

        def canonical_corroboration_path(value)
          URI.parse(value.to_s).path.to_s.gsub(/%[0-9a-f]{2}/i, &:upcase)
        rescue StandardError
          value.to_s
        end

        def demote_homogeneous_guesses!(entries, runtime)
          dominant = homogeneous_guess_cluster(entries, runtime)
          return unless dominant

          entries.each do |entry|
            next if entry[:crawler] || candidate_observation_signature(entry) != dominant
            next unless entry[:decision][:level] == :likely

            entry[:decision] = confidence_decision(:low, :homogeneous_guessed_result)
          end
        end

        def homogeneous_guess_cluster(entries, runtime)
          return if entries.length < HOMOGENEOUS_GUESS_MIN_SAMPLES

          successful = runtime.dig(:stats, :success).to_i
          return if successful <= 0 || entries.length.to_f / successful < HOMOGENEOUS_GUESS_DOMINANCE

          signatures = entries.map { |entry| candidate_observation_signature(entry) }
          dominant, count = signatures.tally.max_by { |_signature, total| total }
          return unless count.to_f / entries.length >= HOMOGENEOUS_GUESS_DOMINANCE

          dominant
        end

        def candidate_observation_signature(entry)
          sample = entry[:sample].to_h
          status = entry[:status]
          [status, sample[:content_type], sample[:title].to_s, sample[:fingerprint], sample[:body_length].to_i]
        end

        def apply_reconciled_runtime_buckets!(runtime, reconciled)
          runtime[:found] = reconciled[:prioritized]
          runtime[:confirmed_found] = reconciled[:confirmed]
          runtime[:low_confidence_found] = reconciled[:low]
          runtime[:stdout_found] = reconciled[:prioritized]
        end

        def reconcile_runtime_for_adaptation!(scan, runtime)
          return unless (runtime[:count].to_i % PRESSURE_WINDOW_REQUESTS).zero?
          return if Array(runtime[:candidate_observations]).empty?

          apply_reconciled_runtime_buckets!(runtime, reconcile_candidate_findings(scan, runtime))
        end

        def apply_reconciled_first_actionable!(runtime, entries)
          first = entries.reject { |entry| entry[:decision][:level] == :low }
                         .min_by { |entry| entry[:observed_count].to_i }
          runtime[:first_actionable_at] = first && first[:observed_at]
          runtime[:first_actionable_count] = first ? first[:observed_count].to_i : 0
        end

        def apply_reconciled_confidence_stats!(stats, entries)
          return if entries.empty?

          stats[:confidence_levels] = entries.map { |entry| entry[:decision][:level].to_s }.tally
          stats[:confidence_reasons] = entries.map { |entry| entry[:decision][:reason].to_s }.reject(&:empty?).tally
          stats[:waf_sensitive_promotion_count] = entries.count do |entry|
            entry[:decision][:level] != :low && sensitive_status_reason?(entry[:decision][:reason])
          end
        end

        def rank_high_signal_paths(responses, normalized_target, prioritized)
          Array(responses)
            .map { |url, status| [url.to_s, score_path_signal(url, status, normalized_target)] }
            .select { |(url, score)| score.positive? && prioritized.include?(url) }
            .sort_by { |(url, score)| [-score, url.length] }
            .first(200)
            .map(&:first)
            .uniq
        end

        def score_path_signal(url, status, normalized_target)
          path = relative_response_path(url, normalized_target)
          return 0 if path.empty? || path == '/'

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
