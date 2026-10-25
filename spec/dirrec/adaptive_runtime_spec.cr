require "../spec_helper"
require "../../src/nokizaru/dirrec/runtime"
require "../../src/nokizaru/dirrec/results"

private def adaptive_plan(size : Int32, extensions = [] of String)
  words = Array.new(size) { |i| "candidate#{i}" }
  Nokizaru::DirRec::UrlPlan.new([] of String, [] of String, words, extensions, size * (1 + extensions.size))
end

private def adaptive_runtime(policy, transport)
  Nokizaru::DirRec::Runtime.new("http://fixture", "http://fixture", nil,
    Nokizaru::DirRec::ConfidenceContext.new(nil, nil), policy: policy, transport: transport)
end

describe "Directory adaptive admission" do
  it "drains a healthy finite plan exactly once with bounded in-flight work" do
    now = Time.instant
    requests = [] of String
    active = peak = 0
    transport = ->(url : String, _options : Nokizaru::Http::Options) do
      requests << url
      active += 1
      peak = Math.max(peak, active)
      Fiber.yield
      active -= 1
      Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    policy = Nokizaru::DirRec::AdaptivePolicy.new(8, 3.0, nil, clock: -> { now }, extensions: true)
    runtime = adaptive_runtime(policy, transport)
    plan = adaptive_plan(2200, ["txt"])
    runtime.run(Nokizaru::DirRec::LazyQueue.new(plan, "http://fixture"), 8, Nokizaru::Http::Options.new)
    requests.size.should eq(4400)
    requests.uniq.size.should eq(4400)
    runtime.count.should eq(4400)
    peak.should eq(8)
    runtime.peak_in_flight.should eq(8)
    policy.stats.stop_reason.should be_nil
  end

  it "stops dispatch at a fake deadline and drains at most the admitted cap" do
    now = Time.instant
    clock = -> { now }
    baseline = Nokizaru::DirRec::Baseline.new(302, redirect_pattern: "root:/")
    policy = Nokizaru::DirRec::AdaptivePolicy.new(4, 10.0, baseline, clock: clock)
    requests = 0
    started = [] of Time::Span
    timeouts = [] of Float64
    transport = ->(_url : String, options : Nokizaru::Http::Options) do
      started << now - policy.start_time
      timeouts << options.timeout_s
      requests += 1
      Fiber.yield
      now = policy.start_time + 420.seconds
      Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    runtime = adaptive_runtime(policy, transport)
    plan = adaptive_plan(1000)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(plan, "http://fixture"), 4, Nokizaru::Http::Options.new)
    requests.should eq(4)
    started.all? { |at| at < 420.seconds }.should be_true
    timeouts.should eq([2.5] * 4)
    runtime.count.should eq(requests)
    runtime.peak_in_flight.should eq(4)
    info = Nokizaru::DirRec::Target.new("http://fixture", "http://fixture", false, "")
    result = Nokizaru::DirRec::Results.assemble(runtime, info, plan, "http://fixture", 4, false)
    result.stats.stop_reason.should eq("time budget hit (420.0s/420.0s)")
    result.stats.elapsed_seconds.should eq(420.0)
    result.stats.total_requests.should eq(4)
    result.stats.mode.should eq("seeded")
    result.stats.adaptive_concurrency.should eq(4)
  end

  it "reduces actual admission under pressure then recovers without new workers" do
    now = Time.instant
    calls = 0
    active = peak_after_pressure = 0
    policy = Nokizaru::DirRec::AdaptivePolicy.new(16, 10.0, nil, clock: -> { now })
    transport = ->(_url : String, _options : Nokizaru::Http::Options) do
      calls += 1
      now += 3.seconds if calls % 80 == 0
      current = calls
      active += 1
      peak_after_pressure = Math.max(peak_after_pressure, active) if calls > 340
      Fiber.yield
      active -= 1
      current <= 160 ? Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "timeout") : Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    runtime = adaptive_runtime(policy, transport)
    plan = adaptive_plan(640)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(plan, "http://fixture"), 16, Nokizaru::Http::Options.new)
    runtime.count.should eq(640)
    runtime.errors.should eq(160)
    policy.stats.pressure_events.should eq(2)
    policy.stats.adaptive_concurrency.should eq(11)
    peak_after_pressure.should be <= 11
    runtime.peak_in_flight.should eq(16)
  end

  it "caps admitted hostile requests exactly, including requests still in flight" do
    now = Time.instant
    calls = 0
    policy = Nokizaru::DirRec::AdaptivePolicy.new(50, 10.0, nil, clock: -> { now })
    transport = ->(_url : String, _options : Nokizaru::Http::Options) do
      calls += 1
      now += 3.seconds if calls % 80 == 0
      failed = calls.even?
      Fiber.yield
      failed ? Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "timeout") : Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    runtime = adaptive_runtime(policy, transport)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(adaptive_plan(5000), "http://fixture"), 50, Nokizaru::Http::Options.new)
    calls.should eq(1800)
    runtime.count.should eq(1800)
    runtime.errors.should eq(900)
    policy.stats.stop_reason.should eq("request budget hit (1800/1800)")
    policy.stats.stop_reason_display.should eq("Request limit reached")
    policy.stats.adaptive_concurrency.should eq(2)
    runtime.peak_in_flight.should eq(50)
  end

  it "stops uniform low-value redirects from current summaries and drains bounded work" do
    response = Nokizaru::Http::Result.ok(302, HTTP::Headers{"Location" => "/"}, "", false)
    sample = Nokizaru::DirRec::Sampler.sample(response, "http://fixture/random").not_nil!
    baseline = Nokizaru::DirRec::Soft404.build_from_samples([sample, sample, sample])
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(10, 3.0, baseline, clock: -> { now }, extensions: true)
    calls = 0
    transport = ->(_url : String, _options : Nokizaru::Http::Options) do
      calls += 1
      now += 3.seconds if calls % 80 == 0
      Fiber.yield
      response
    end
    runtime = Nokizaru::DirRec::Runtime.new("http://fixture", "http://fixture", baseline,
      Nokizaru::DirRec::ConfidenceContext.new(nil, nil), policy: policy, transport: transport)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(adaptive_plan(2000, ["txt"]), "http://fixture"), 10, Nokizaru::Http::Options.new)
    calls.should be >= 320
    calls.should be <= 329
    runtime.count.should eq(calls)
    policy.stats.stop_reason.should eq("marginal directory value collapsed under dominant target shape")
    policy.stats.extension_phase_enabled?.should be_false
    policy.stats.pressure_window_prioritized_gain.should eq(0)
    policy.stats.low_yield_events.should eq(4)
    policy.stats.pressure_events.should eq(4)
  end

  it "dispatches extensions reenabled by the last in-flight base response" do
    redirect = Nokizaru::Http::Result.ok(302, HTTP::Headers{"Location" => "/"}, "", false)
    sample = Nokizaru::DirRec::Sampler.sample(redirect, "http://fixture/random").not_nil!
    baseline = Nokizaru::DirRec::Soft404.build_from_samples([sample, sample, sample])
    now = Time.instant
    policy = Nokizaru::DirRec::AdaptivePolicy.new(2, 3.0, baseline, clock: -> { now }, extensions: true)
    requests = [] of String
    disabled_at_boundary = false
    transport = ->(url : String, _options : Nokizaru::Http::Options) do
      requests << url
      number = requests.size
      now += 3.seconds if number == 80 || number == 160
      disabled_at_boundary = !policy.stats.extension_phase_enabled? if number == 160
      Fiber.yield
      number <= 80 ? redirect : Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    runtime = Nokizaru::DirRec::Runtime.new("http://fixture", "http://fixture", baseline,
      Nokizaru::DirRec::ConfidenceContext.new(nil, nil), policy: policy, transport: transport)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(adaptive_plan(160, ["txt"]), "http://fixture"), 2, Nokizaru::Http::Options.new)
    disabled_at_boundary.should be_true
    requests.size.should eq(320)
    requests.count(&.ends_with?(".txt")).should eq(160)
    requests.uniq.size.should eq(320)
    runtime.count.should eq(320)
    policy.stats.extension_phase_enabled?.should be_true
    policy.stats.stop_reason.should be_nil
  end

  it "accounts a response-processing exception once and continues with the next response" do
    now = Time.instant
    fail_observation = false
    clock = -> do
      if fail_observation
        fail_observation = false
        raise "observation failed"
      end
      now
    end
    policy = Nokizaru::DirRec::AdaptivePolicy.new(1, 3.0, nil, clock: clock)
    calls = 0
    transport = ->(_url : String, _options : Nokizaru::Http::Options) do
      calls += 1
      fail_observation = calls == 1
      Nokizaru::Http::Result.ok(200, HTTP::Headers{"Content-Type" => "text/html"}, "<title>valid</title>", false)
    end
    runtime = adaptive_runtime(policy, transport)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(adaptive_plan(2), "http://fixture"), 1, Nokizaru::Http::Options.new)
    runtime.count.should eq(2)
    runtime.success.should eq(1)
    runtime.errors.should eq(1)
    runtime.error_kinds.should eq({"other" => 1})
    runtime.responses.should eq([{"http://fixture/candidate1", 200}])
    runtime.observations.map(&.observed_count).should eq([2])
  end
end
