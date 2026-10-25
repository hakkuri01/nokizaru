require "../spec_helper"
require "../../src/nokizaru/dirrec/adaptive_policy"

private def adaptive_context
  Nokizaru::DirRec::ConfidenceContext.new(nil, nil)
end

private def policy_window(policy, context, status = 404, error : String? = nil, prioritized = false, count = 80)
  count.times { policy.observe(error ? nil : status, error, prioritized, context.snapshot) }
end

describe Nokizaru::DirRec::AdaptivePolicy do
  it "leaves healthy finite plans unlimited even after long elapsed time" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, nil, clock: -> { now })
    context = adaptive_context
    100.times { policy_window(policy, context) }
    policy.stats.pressure_events.should eq(0)
    now += 1.day
    policy.observe(404, nil, false, context.snapshot)
    policy.stopped?(8000).should be_false
    policy.stats.mode.should eq("full")
    policy.stats.max_requests.should eq(0)
    policy.stats.budget_seconds.should eq(0)
    policy.stats.pressure_events.should eq(0)
  end

  it "halves admission under transport pressure and recovers additively" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, nil, clock: -> { now })
    context = adaptive_context
    2.times do
      now += 3.seconds
      80.times { |i| policy.observe(i.even? ? 404 : nil, i.even? ? nil : "timeout", false, context.snapshot) }
    end
    policy.stats.adaptive_concurrency.should eq(20)
    policy.stats.mode.should eq("seeded")
    policy.stats.pressure_events.should eq(2)
    policy.stats.pressure_window_transport_ratio.should eq(0.5)
    2.times do
      now += 3.seconds
      80.times { |i| policy.observe(i.even? ? 404 : nil, i.even? ? nil : "timeout", false, context.snapshot) }
    end
    policy.stats.adaptive_concurrency.should eq(10)
    policy.stats.mode.should eq("hostile")
    policy.stats.timeout_downshifts.should eq(2)
    policy.timeout_s.should eq(1.5)
    4.times do
      now += 3.seconds
      policy_window(policy, context)
    end
    policy.stats.adaptive_concurrency.should eq(12)
    policy.stats.pressure_streak.should eq(0)
    policy.stats.mode_downshifts.should eq(2)
    policy.stopped?(640).should be_false
  end

  it "enforces hostile deadlines and admission request budgets exactly" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, nil, clock: -> { now })
    context = adaptive_context
    # Pressure without total transport collapse lets the budget decide the stop
    4.times do
      now += 3.seconds
      80.times { |i| policy.observe(nil, i.even? ? "timeout" : nil, false, context.snapshot) }
    end
    policy.stopped?(1799).should be_false
    now = policy.start_time + 180.seconds
    policy.stopped?(1799).should be_true
    policy.stats.stop_reason.should eq("time budget hit (180.0s/180.0s)")
    policy.stats.stop_reason_display.should eq("Time limit reached")
    policy.stats.budget_seconds.should eq(180.0)
    policy.stats.max_requests.should eq(1800)
  end

  it "reduces admission for explicit rate limiting without inventing transport errors" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, nil, clock: -> { now })
    context = adaptive_context
    2.times do
      now += 3.seconds
      policy_window(policy, context, status: 429)
    end
    policy.stats.adaptive_concurrency.should eq(20)
    policy.stats.mode.should eq("seeded")
    policy.stats.pressure_events.should eq(2)
    policy.stats.pressure_window_error_ratio.should eq(0.0)
    policy.stats.pressure_window_transport_ratio.should eq(0.0)
  end

  it "does not turn thousands of sub-three-second responses into pressure windows" do
    baseline = Nokizaru::DirRec::Baseline.new(200, content_type: "text/html", fingerprint: "wildcard")
    sample = Nokizaru::DirRec::Sample.new(200, content_type: "text/html", fingerprint: "wildcard")
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, baseline, clock: -> { now }, extensions: true)
    context = adaptive_context
    4_000.times do
      context.update!(200, sample, baseline)
      policy.observe(200, nil, false, context.snapshot)
    end
    policy.stopped?(4_000).should be_false
    policy.stats.pressure_events.should eq(0)
    policy.stats.low_yield_events.should eq(0)
    policy.stats.extension_phase_enabled?.should be_true

    3.times do |window|
      now += 3.seconds
      count = window == 0 ? 1 : 80
      count.times do
        context.update!(200, sample, baseline)
        policy.observe(200, nil, false, context.snapshot)
      end
      policy.stopped?(4_000 + 1 + window * 80).should eq(window == 2)
    end
    policy.stats.stop_reason.should eq("marginal directory value collapsed under dominant target shape")
    policy.stats.stop_status_code_shape.should eq("200=4161/4161 (100.0%)")
    policy.stats.low_yield_events.should eq(3)
    policy.stats.pressure_window_prioritized_gain.should eq(0)
  end

  it "normalizes ratios by the accumulated window count and keeps the 80-candidate floor" do
    baseline = Nokizaru::DirRec::Baseline.new(200, content_type: "text/html", fingerprint: "wildcard")
    sample = Nokizaru::DirRec::Sample.new(200, content_type: "text/html", fingerprint: "wildcard")
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, baseline, clock: -> { now }, extensions: true)
    context = adaptive_context
    20.times { policy.observe(nil, "timeout", false, context.snapshot) }
    79.times do
      context.update!(200, sample, baseline)
      policy.observe(200, nil, false, context.snapshot)
    end
    now += 3.seconds
    policy.observe(404, nil, false, context.snapshot)

    policy.stats.pressure_window_error_ratio.should be_close(0.2, 0.000001)
    policy.stats.pressure_window_transport_ratio.should be_close(0.2, 0.000001)
    policy.stats.low_yield_events.should eq(0)
    policy.stats.extension_phase_enabled?.should be_true
  end

  it "evaluates concurrency after variable-sized eligible windows without modulo boundaries" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(16, 10.0, nil, clock: -> { now })
    context = adaptive_context
    100.times { |i| policy.observe(i.even? ? 404 : nil, i.even? ? nil : "timeout", false, context.snapshot) }
    now += 3.seconds
    policy.observe(nil, "timeout", false, context.snapshot)
    policy.stats.adaptive_concurrency.should eq(16)
    policy.stats.pressure_window_transport_ratio.should be_close(51.0 / 101.0, 0.000001)

    now += 3.seconds
    policy_window(policy, context, error: "timeout")
    policy.stats.adaptive_concurrency.should eq(8)
    policy.stats.mode.should eq("seeded")
    policy.stats.pressure_events.should eq(2)
  end

  it "does not mistake productive dominant targets for collapsed value" do
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(10, 1.0, nil, clock: -> { now }, extensions: true)
    context = adaptive_context
    sample = Nokizaru::DirRec::Sample.new(302, redirect_pattern: "root:/")
    10.times do
      now += 3.seconds
      80.times do
        context.update!(302, sample, nil)
        policy.observe(302, nil, true, context.snapshot)
      end
    end
    policy.stopped?(800).should be_false
    policy.stats.extension_phase_enabled?.should be_true
    policy.timeout_s.should eq(1.0)
  end
end
