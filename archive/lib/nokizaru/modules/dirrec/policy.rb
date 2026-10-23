# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Policy
        private

        def maybe_stop!(runtime)
          return unless should_stop_now?(runtime[:count], runtime[:start_time], runtime[:stop_state])

          stop!(runtime[:stop_state], runtime[:count], runtime[:start_time], runtime[:client], runtime: runtime)
        end

        def adapt_timeout_if_needed!(scan, runtime)
          return unless should_adapt_timeout?(runtime[:count], runtime[:stats], runtime[:timeout_state])

          rebuild = rebuild_client_with_lower_timeout(client_config(scan, runtime))
          runtime[:client], runtime[:timeout_state] = rebuild
          runtime[:stats][:timeout_downshifts] += 1
          with_output_lock(runtime) do
            UI.row(:plus, 'Adaptive Timeout', "reduced to #{runtime[:timeout_state][:current]}s (timeout-heavy target)")
          end
          print_progress(runtime, scan, force: true)
        end

        def client_config(scan, runtime)
          {
            client: runtime[:client],
            timeout_state: runtime[:timeout_state],
            target: scan[:scan_target],
            allow_redirects: scan[:options][:allow_redirects],
            request_headers: scan[:options][:request_headers],
            verify_ssl: scan[:options][:verify_ssl],
            threads: thread_cap_for_mode(runtime[:stop_state][:mode], scan[:options][:threads].to_i)
          }
        end

        def seeded_preflight?(ratios)
          return true if ratios[:redirect] >= 0.4 && ratios[:generic] >= 0.7

          return true if ratios[:error] >= PREFLIGHT_SEEDED_ERROR_RATIO

          ratios[:timeout] >= PREFLIGHT_SEEDED_TIMEOUT_RATIO
        end

        def timeout_for_mode(mode, base_timeout)
          base = base_timeout.to_f
          return base if base <= 0

          case mode
          when MODE_HOSTILE
            [base, MIN_ADAPTIVE_TIMEOUT_S].min
          when MODE_SEEDED
            [base, PROTECTED_TIMEOUT_S].min
          else
            base
          end
        end

        def request_method_for_mode(mode)
          mode.to_s == MODE_HOSTILE ? :head : :get
        end

        def thread_cap_for_mode(mode, threads)
          value = threads.to_i
          return [value, 1].max if mode == MODE_FULL

          cap = mode == MODE_HOSTILE ? 12 : 20
          value.clamp(1, cap)
        end

        def should_stop_now?(count, start_time, stop_state)
          return true if stop_state[:stop]

          budgets = stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
          max_requests = budgets[:max_requests].to_i
          budget_s = budgets[:budget_s].to_f

          return true if max_requests.positive? && count >= max_requests
          return true if budget_s.positive? && (Time.now - start_time) >= budget_s

          false
        end

        def stop!(stop_state, count, start_time, client = nil, runtime: nil)
          return if stop_state[:stop]

          budgets = stop_budgets(stop_state)
          stop_state[:stop] = true
          stop_state[:reason] ||= stop_reason(budgets, count, start_time)
          capture_stop_status_code_shape!(runtime) if runtime

          close_client!(stop_state, client)
        end

        def stop_budgets(stop_state)
          stop_state[:budgets].is_a?(Hash) ? stop_state[:budgets] : {}
        end

        def stop_reason(budgets, count, start_time)
          max_requests = budgets[:max_requests].to_i
          return "request budget hit (#{count}/#{max_requests})" if max_requests.positive? && count >= max_requests

          budget_s = budgets[:budget_s].to_f
          elapsed = Time.now - start_time
          return "time budget hit (#{elapsed.round(2)}s/#{budget_s}s)" if budget_s.positive? && elapsed >= budget_s

          'stopped'
        end

        # Clamp directory enumeration timeout to reduce long-tail stalls on strict targets
        def effective_timeout_s(timeout_s, target_profile: nil, header_map: nil, allow_redirects: false)
          timeout = timeout_s.to_f
          base = if timeout.positive?
                   [timeout, MAX_EFFECTIVE_TIMEOUT_S].min
                 else
                   DEFAULT_EFFECTIVE_TIMEOUT_S
                 end

          return base unless protected_target?(target_profile, header_map, allow_redirects)

          [base, PROTECTED_TIMEOUT_S].min
        end

        # Detect protected edge configurations where lower timeouts preserve throughput under high challenge/error rates
        def protected_target?(target_profile, header_map, allow_redirects)
          return false if allow_redirects

          mode = target_profile_mode(target_profile)
          edge_provider?(header_map) || !mode.empty?
        end

        def target_profile_mode(target_profile)
          target_profile.is_a?(Hash) ? target_profile['mode'].to_s : ''
        end

        def edge_provider?(header_map)
          headers = header_map.is_a?(Hash) ? header_map : {}
          server = headers['server'].to_s.downcase
          powered_by = headers['x-powered-by'].to_s.downcase
          edge_vendor?(server) || powered_by.include?('cloudflare')
        end

        def edge_vendor?(server)
          %w[cloudflare akamai sucuri imperva].any? { |vendor| server.include?(vendor) }
        end

        def should_adapt_timeout?(count, stats, timeout_state)
          return false if count < TIMEOUT_ADAPT_SAMPLE_SIZE
          return false if timeout_state[:current] <= timeout_state[:min]

          timeout_errors = stats[:error_kinds]['timeout'].to_i
          return false if timeout_errors.zero?

          (timeout_errors.to_f / count) >= TIMEOUT_ADAPT_ERROR_RATIO
        end

        # Rebuild bulk HTTP client with lower timeout to keep directory scan throughput stable on protected targets
        def rebuild_client_with_lower_timeout(config)
          client = config[:client]
          timeout_state = config[:timeout_state]
          next_timeout = next_timeout_value(timeout_state)
          return [client, timeout_state] if next_timeout >= timeout_state[:current]

          refreshed = rebuild_client_with_timeout(config, next_timeout)

          [refreshed, timeout_state.merge(current: next_timeout)]
        rescue StandardError
          [client, timeout_state]
        end

        def next_timeout_value(timeout_state)
          [(timeout_state[:current] * 0.6).round(2), timeout_state[:min]].max
        end

        def rebuild_client(config)
          client = config[:client]
          timeout_state = config[:timeout_state]
          refreshed = rebuild_client_with_timeout(config, timeout_state[:current].to_f)
          [refreshed, timeout_state]
        rescue StandardError
          [client, timeout_state]
        end

        def rebuild_client_with_timeout(config, timeout)
          Nokizaru::HTTPClient.for_bulk_requests(
            config[:target],
            timeout_s: timeout,
            headers: { 'User-Agent' => DEFAULT_UA },
            follow_redirects: follow_redirects_for_client(config[:allow_redirects], config[:request_headers]),
            verify_ssl: config[:verify_ssl],
            max_concurrent: [config[:threads].to_i, 1].max,
            retries: 0
          )
        end

        def apply_mode_downgrade!(count, stats, stop_state, timeout_state, runtime: nil)
          return nil if stop_state[:stop]
          return nil if count < 80

          current_mode = stop_state[:mode].to_s

          if runtime
            adaptive = apply_pressure_mode_downgrade!(count, stop_state, timeout_state, runtime)
            return adaptive if adaptive
          end

          return nil if current_mode == MODE_HOSTILE

          if current_mode == MODE_FULL && low_signal_saturation?(count, stats)
            return apply_seeded_mode!(stop_state, timeout_state)
          end

          return nil unless hostile_runtime_ratios?(count, stats)

          apply_hostile_mode!(stop_state, timeout_state)
        end

        def apply_pressure_mode_downgrade!(count, stop_state, timeout_state, runtime)
          state = runtime[:adaptation_state]
          return nil unless state.is_a?(Hash)

          current_mode = stop_state[:mode].to_s
          pressure_streak = state[:pressure_streak].to_i
          low_yield_streak = state[:low_yield_streak].to_i

          stopped = apply_hostile_no_signal_stop!(current_mode, count, stop_state, runtime[:stats], runtime)
          return stopped if stopped

          if seeded_pressure_downgrade?(current_mode, count, pressure_streak)
            return apply_seeded_mode!(stop_state, timeout_state)
          end

          if hostile_pressure_downgrade?(current_mode, count, pressure_streak, low_yield_streak)
            return apply_hostile_mode!(stop_state, timeout_state)
          end

          if hostile_low_yield_stop?(current_mode, pressure_streak, low_yield_streak)
            stop_state[:stop] = true
            stop_state[:reason] ||= hostile_low_yield_stop_reason(state)
            capture_stop_status_code_shape!(runtime)
            return :stopped
          end

          nil
        end

        def seeded_pressure_downgrade?(current_mode, count, pressure_streak)
          current_mode == MODE_FULL && count >= 160 && pressure_streak >= PRESSURE_SEEDED_STREAK
        end

        def hostile_pressure_downgrade?(current_mode, count, pressure_streak, low_yield_streak)
          current_mode == MODE_SEEDED && count >= 320 && pressure_streak >= PRESSURE_HOSTILE_STREAK &&
            low_yield_streak >= LOW_YIELD_HOSTILE_STREAK
        end

        def hostile_low_yield_stop?(current_mode, pressure_streak, low_yield_streak)
          current_mode == MODE_HOSTILE && pressure_streak >= PRESSURE_HOSTILE_STREAK &&
            low_yield_streak >= LOW_YIELD_STOP_STREAK
        end

        def hostile_low_yield_stop_reason(state)
          'sustained hostile pressure with low prioritized yield ' \
            "(pressure_streak=#{state[:pressure_streak]}, low_yield_streak=#{state[:low_yield_streak]})"
        end

        def apply_hostile_no_signal_stop!(current_mode, count, stop_state, stats, runtime = nil)
          return nil unless hostile_no_signal_stop?(current_mode, count, stats)

          stop_state[:stop] = true
          stop_state[:reason] ||= hostile_no_signal_stop_reason(count, stats)
          capture_stop_status_code_shape!(runtime) if runtime
          :stopped
        end

        def hostile_no_signal_stop?(current_mode, count, stats)
          return false unless current_mode == MODE_HOSTILE
          return false if count < HOSTILE_NO_SIGNAL_MIN_REQUESTS
          return false unless stats.is_a?(Hash)

          successes = stats[:success].to_i
          errors = stats[:errors].to_i
          return false if successes > HOSTILE_NO_SIGNAL_MAX_SUCCESS

          errors.fdiv(count) >= HOSTILE_NO_SIGNAL_ERROR_RATIO
        end

        def hostile_no_signal_stop_reason(count, stats)
          'sustained hostile transport failures with no useful signal ' \
            "(requests=#{count}, success=#{stats[:success].to_i}, errors=#{stats[:errors].to_i})"
        end

        def low_signal_saturation?(count, stats)
          return false if count < 160

          positive_statuses = stats[:positive_statuses].is_a?(Hash) ? stats[:positive_statuses] : {}
          positive_total = positive_statuses.values.sum
          return false if positive_total < 60

          dominant = positive_statuses[200].to_i + positive_statuses[401].to_i + positive_statuses[403].to_i
          positive_ratio = positive_total.to_f / count
          dominant_ratio = dominant.to_f / positive_total
          positive_ratio >= 0.32 && dominant_ratio >= 0.9
        end

        def hostile_runtime_ratios?(count, stats)
          errors = stats[:errors].to_i
          timeouts = stats[:error_kinds]['timeout'].to_i
          (timeouts.to_f / count) >= 0.08 || (errors.to_f / count) >= 0.75
        end

        def apply_hostile_mode!(stop_state, timeout_state)
          stop_state[:mode] = MODE_HOSTILE
          stop_state[:budgets] = MODE_BUDGETS.fetch(MODE_HOSTILE)
          stop_state[:request_method] = request_method_for_mode(MODE_HOSTILE)
          timeout_state[:current] = timeout_for_mode(MODE_HOSTILE, timeout_state[:current])
          :downgraded
        end

        def apply_seeded_mode!(stop_state, timeout_state)
          stop_state[:mode] = MODE_SEEDED
          stop_state[:budgets] = MODE_BUDGETS.fetch(MODE_SEEDED)
          stop_state[:request_method] = request_method_for_mode(MODE_SEEDED)
          timeout_state[:current] = timeout_for_mode(MODE_SEEDED, timeout_state[:current])
          :downgraded
        end

        def close_client!(stop_state, client)
          return unless client
          return if stop_state[:client_closed]

          stop_state[:client_closed] = true
          client.close if client.respond_to?(:close)
        rescue StandardError
          nil
        end

        # Group transport failures so adaptive timeout logic can react to dominant failure classes
        def classify_error(http_result)
          error = http_result.error
          message = http_result.error_message.to_s.downcase

          return 'timeout' if timeout_error?(message, error)
          return 'tls' if defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
          return 'connection' if connection_error_message?(message)

          'other'
        end

        def timeout_error?(message, error)
          timeout_message?(message) || timeout_exception?(error)
        end

        def timeout_message?(message)
          message.include?('timeout') || message.include?('timed out') ||
            message.include?('waiting on select') || message.include?('waited')
        end

        def timeout_exception?(error)
          timeout_error_classes.any? { |klass| klass && error.is_a?(klass) }
        end

        def timeout_error_classes
          [
            (defined?(Timeout::Error) ? Timeout::Error : nil),
            (defined?(Errno::ETIMEDOUT) ? Errno::ETIMEDOUT : nil),
            (defined?(IO::TimeoutError) ? IO::TimeoutError : nil),
            (defined?(HTTPX::TimeoutError) ? HTTPX::TimeoutError : nil)
          ]
        end

        def connection_error_message?(message)
          message.include?('connection') || message.include?('reset') || message.include?('refused') ||
            message.include?('stream closed')
        end
      end
    end
  end
end
