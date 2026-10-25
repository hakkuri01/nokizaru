require "./result"
require "./context"

module Nokizaru::DirRec
  # Fixed counters, not a history: O(1) per completion and admission
  class AdaptivePolicy
    WINDOW     = 80
    MIN_WINDOW = 3.seconds
    # Requests between wall checks: one collapsed stride triggers adaptation, a
    # second collapsed stride (after adapting) means the adversary persisted.
    WALL_STRIDE = 120

    getter stats = Stats.new
    getter timeout_s : Float64
    getter start_time : Time::Instant
    @maximum : Int32
    @window_start : Time::Instant

    def initialize(concurrency : Int32, @timeout_s : Float64, baseline : Baseline?, *, @clock : Proc(Time::Instant) = -> { Time.instant }, extensions : Bool = false)
      @maximum = Math.max(concurrency, 1)
      @stats.adaptive_concurrency = @maximum
      @start_time = @clock.call
      @window_start = @start_time
      @extensions = extensions
      @stats.extension_phase_enabled = extensions
      @stats.extension_phase_reason = extensions ? "extensions_provided" : nil
      @stats.preflight = baseline ? "existing soft-404 probes supplied baseline" : "existing soft-404 probes supplied no stable baseline"
      if baseline && (Fields.generic_redirect_pattern?(baseline.redirect_pattern || "") || baseline.status == 403 || baseline.status == 429)
        downgrade("seeded")
      end
    end

    @count = 0
    @window_count = 0
    @concurrency_count = 0
    @window_errors = 0
    @window_transport = 0
    @window_timeouts = 0
    @window_throttled = 0
    @window_candidates = 0
    @window_gain = 0
    @gain_total = 0
    @candidate_total = 0
    @candidates_at_check = 0
    @wall_adapted = false
    @wall_check_at = 0
    @gain_at_check = 0
    @successful = 0
    @concurrency_pressure = false
    @concurrency_clean = true
    @statuses = Hash(Int32, Int32).new(0)

    def stopped?(dispatched : Int32) : Bool
      return true if @stats.stop_reason

      if @stats.max_requests > 0 && dispatched >= @stats.max_requests
        stop("request budget hit (#{dispatched}/#{@stats.max_requests})", "Request limit reached")
      elsif @stats.budget_seconds > 0 && elapsed_seconds >= @stats.budget_seconds
        stop("time budget hit (#{elapsed_seconds.round(2)}s/#{@stats.budget_seconds}s)", "Time limit reached")
      end
      !@stats.stop_reason.nil?
    end

    def elapsed_seconds : Float64
      (now - @start_time).total_seconds
    end

    def now : Time::Instant
      @clock.call
    end

    def observe(status : Int32?, error_kind : String?, prioritized : Bool, snap : ConfidenceContext::Snapshot) : Nil
      accumulate(status, error_kind, prioritized)
      evaluate(snap) if @window_count >= WINDOW
      track_wall(snap)
    end

    private def accumulate(status : Int32?, error_kind : String?, prioritized : Bool) : Nil
      @count += 1
      @window_count += 1
      if status
        @statuses[status] += 1
        @successful += 1
      end
      @window_errors += 1 if error_kind
      @window_transport += 1 if {"timeout", "connection", "tls"}.includes?(error_kind)
      @window_timeouts += 1 if error_kind == "timeout"
      @window_throttled += 1 if status == 429 || status == 503
      if status && FINDING_CANDIDATE_STATUSES.includes?(status)
        @window_candidates += 1
        @candidate_total += 1
      end
      if prioritized
        @window_gain += 1
        @gain_total += 1
      end
    end

    private def evaluate(snap : ConfidenceContext::Snapshot) : Nil
      evaluated_at = now
      elapsed = evaluated_at - @window_start
      return if elapsed < MIN_WINDOW

      @stats.pressure_window_avg_rps = @window_count / elapsed.total_seconds
      @stats.pressure_window_error_ratio = @window_errors / @window_count.to_f
      @stats.pressure_window_transport_ratio = @window_transport / @window_count.to_f
      @stats.pressure_window_prioritized_gain = @window_gain
      transport_pressure = update_pressure(snap)
      low = @window_candidates >= WINDOW && @window_gain <= 2
      @stats.low_yield_events += 1 if low
      @stats.low_yield_streak = low ? @stats.low_yield_streak + 1 : 0
      @concurrency_pressure ||= transport_pressure
      @concurrency_clean &&= @stats.pressure_window_error_ratio <= 0.08 && @stats.pressure_window_transport_ratio <= 0.08
      @concurrency_count += @window_count
      tune_concurrency if @concurrency_count >= 160
      tune_mode(transport_pressure)
      tune_timeout
      tune_shape(snap, low)
      reset_window(evaluated_at)
    end

    private def update_pressure(snap : ConfidenceContext::Snapshot) : Bool
      throttled_ratio = @window_throttled / @window_count.to_f
      transport_pressure = @stats.pressure_window_error_ratio >= 0.35 || @stats.pressure_window_transport_ratio >= 0.20 || throttled_ratio >= 0.20
      @stats.pressure_score = (@stats.pressure_window_error_ratio >= 0.35 ? 1 : 0) + (@stats.pressure_window_transport_ratio >= 0.20 ? 1 : 0) +
                              (snap.waf_likelihood_score >= 0.72 ? 1 : 0) + (snap.redirect_cluster_dominance_ratio >= 0.92 ? 1 : 0) +
                              (throttled_ratio >= 0.20 ? 1 : 0)
      pressure = transport_pressure || @stats.pressure_score >= 2
      @stats.pressure_events += 1 if pressure
      @stats.pressure_streak = pressure ? @stats.pressure_streak + 1 : 0
      transport_pressure
    end

    private def tune_concurrency : Nil
      current = @stats.adaptive_concurrency
      if @concurrency_pressure
        current = Math.max(current // 2, Math.min(2, @maximum))
      elsif @concurrency_clean
        ceiling = @stats.mode == "hostile" ? 12 : (@stats.mode == "seeded" ? 20 : @maximum)
        current = Math.min(current + 1, Math.min(ceiling, @maximum))
      end
      @stats.adaptive_concurrency = current
      @concurrency_count = 0
      @concurrency_pressure = false
      @concurrency_clean = true
    end

    private def tune_mode(transport_pressure : Bool) : Nil
      if @stats.pressure_streak >= 4 && (transport_pressure || @stats.low_yield_streak >= 3)
        downgrade("hostile")
      elsif @stats.pressure_streak >= 2 && @stats.mode == "full"
        downgrade("seeded")
      end
      return unless @stats.mode == "hostile" && @count >= 320

      if @stats.pressure_window_transport_ratio >= 0.90 && @successful <= 4
        stop("sustained hostile transport failures with no useful signal", "Hostile transport failures limited reliable checks")
      elsif @stats.pressure_streak >= 4 && @stats.low_yield_streak >= 5
        stop("sustained hostile pressure with low prioritized yield", "Hostile pressure with low reliable yield")
      end
    end

    private def tune_timeout : Nil
      return unless @count >= 240 && @window_timeouts / @window_count.to_f >= 0.20

      lower_timeout(Math.max(@timeout_s * 0.6, 1.5))
    end

    # Extension-phase tuning only: a dominant low-information shape (or hostile
    # transport) turns off the extension pass so we do not multiply dead probes.
    # The old marginal-value stop here is replaced by the request-strided wall
    # tracker (track_wall), which adapts before it quits and reports what it tried.
    private def tune_shape(snap : ConfidenceContext::Snapshot, low : Bool) : Nil
      return unless @extensions

      dominant = snap.soft_404_dominance_ratio >= 0.92 || snap.redirect_cluster_dominance_ratio >= 0.92
      enabled = !(dominant && low) && @stats.mode != "hostile"
      @stats.extension_phase_enabled = enabled
      @stats.extension_phase_reason = enabled ? "useful extension phase" : "dominant low-information target shape or hostile transport"
    end

    # The adversarial lifecycle (classify -> adapt -> verify -> quit). Checked once
    # per stride of requests, not per time window, so it works against a fast
    # target where no 3-second window ever closes. A collapsed stride (a dominant
    # wall yielding at most one new finding) first triggers adaptation: a block
    # wall gets concurrency cut and the rate lowered, a wildcard is just noted.
    # If the next stride is still collapsed, the adversary persisted despite the
    # adaptation, so the scan stops and the finding reports exactly what was tried.
    private def track_wall(snap : ConfidenceContext::Snapshot) : Nil
      return if @stats.stop_reason
      stride = @count - @wall_check_at
      return if stride < WALL_STRIDE

      # The wall is only CURRENTLY active if this stride was actually full of
      # candidate responses (a receded wall leaves honest 404s, which are not
      # candidates), yielded no new finding, and the shape is dominant.
      candidate_share = (@candidate_total - @candidates_at_check) / stride.to_f
      collapsed = wall_dominant?(snap) && candidate_share >= 0.5 && (@gain_total - @gain_at_check) <= 1
      if collapsed && @wall_adapted
        stop_wall_persisted
      elsif collapsed
        adapt_to_wall
      else
        @wall_adapted = false
      end
      @wall_check_at = @count
      @gain_at_check = @gain_total
      @candidates_at_check = @candidate_total
    end

    private def wall_dominant?(snap : ConfidenceContext::Snapshot) : Bool
      snap.soft_404_dominance_ratio >= 0.92 || snap.redirect_cluster_dominance_ratio >= 0.92
    end

    private def adapt_to_wall : Nil
      @wall_adapted = true
      if block_wall?
        downgrade("hostile")
        @stats.adversary_adaptation = "cut concurrency from #{@maximum} to #{@stats.adaptive_concurrency} and lowered the request rate"
      else
        @stats.adversary_adaptation = "recognized a catch-all/soft-404 wildcard and suppressed matching responses"
      end
    end

    private def block_wall? : Bool
      top = @statuses.max_by? { |(_code, count)| count }
      return false if top.nil?

      {403, 406, 429, 503}.includes?(top[0])
    end

    private def stop_wall_persisted : Nil
      @stats.adversary_persisted = true
      if block_wall?
        stop("defensive wall persisted after adaptation", "Blocking persisted after the scan slowed down")
      elsif redirect_wall?
        stop("uniform redirect wall; directory enumeration exhausted", "Uniform redirects: further probing yields no new paths")
      else
        stop("soft-404 wildcard; directory enumeration exhausted", "Soft-404 wildcard: further probing yields no new paths")
      end
    end

    private def redirect_wall? : Bool
      top = @statuses.max_by? { |(_code, count)| count }
      return false if top.nil?

      REDIRECT_STATUSES.includes?(top[0])
    end

    private def downgrade(mode : String) : Nil
      return if @stats.mode == mode || @stats.mode == "hostile"

      @stats.mode = mode
      @stats.mode_downshifts += 1
      hostile = mode == "hostile"
      @stats.budget_seconds = hostile ? 180.0 : 420.0
      @stats.max_requests = hostile ? 1800 : 0
      @stats.adaptive_concurrency = Math.min(@stats.adaptive_concurrency, hostile ? 12 : 20)
      lower_timeout(hostile ? 1.5 : 2.5)
    end

    private def lower_timeout(value : Float64) : Nil
      return unless value < @timeout_s

      @timeout_s = value
      @stats.timeout_downshifts += 1
    end

    private def reset_window(evaluated_at : Time::Instant) : Nil
      @window_count = 0
      @window_errors = @window_transport = @window_timeouts = 0
      @window_throttled = 0
      @window_candidates = @window_gain = 0
      @window_start = evaluated_at
    end

    private def stop(reason : String, display : String) : Nil
      return if @stats.stop_reason

      @stats.stop_reason = reason
      @stats.stop_reason_display = display
      # HTTP status keys are bounded to the protocol's fixed code space
      total = @statuses.values.sum
      @stats.stop_status_code_shape = @statuses.to_a.sort_by { |(code, count)| {-count, code} }.map do |(code, count)|
        "#{code}=#{count}/#{total} (#{(count * 100.0 / total).round(1)}%)"
      end.join(", ") unless total == 0
    end
  end
end
