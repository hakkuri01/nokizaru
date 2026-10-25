require "../spec_helper"
require "json"
require "../../src/nokizaru/dirrec/results"
require "../../src/nokizaru/dirrec/soft404"

private def reflection_allocations(url : String) : UInt64
  GC.collect
  before = GC.stats.total_bytes
  Nokizaru::DirRec::Fields.body_fingerprint("request blocked", url)
  GC.stats.total_bytes - before
end

describe "Ruby directory classifier replay" do
  # Pinned by replaying the archived helpers, not bodies recovered from exports
  JSON.parse(File.read("#{__DIR__}/parity_cases.json")).as_a.each do |fixture|
    it "matches Ruby's fingerprint and soft-404 decision for #{fixture["name"].as_s}" do
      url = fixture["url"].as_s
      fingerprint = Nokizaru::DirRec::Fields.body_fingerprint(fixture["body"].as_s, url)
      fingerprint.should eq(fixture["fingerprint"].as_s)
      {200, 403}.each do |status|
        sample = Nokizaru::DirRec::Sample.new(status, content_type: "text/html", body_length: 700, fingerprint: fingerprint)
        baseline = Nokizaru::DirRec::Baseline.new(status, content_type: "text/html", body_length: 1000, tolerance: 128, fingerprint: fixture["fingerprint"].as_s)
        decision = Nokizaru::DirRec::Confidence.finding_confidence(url, status, sample, baseline, "https://x.com")
        {decision.level, decision.reason}.should eq({"low", "soft_404_signature_match"})
      end
    end
  end

  it "clusters encoded path redirects without swallowing path-specific suffixes" do
    samples = %w[alpha charlie].map do |segment|
      url = "https://x.com/reflected-redirect/#{segment}"
      location = "/locale/%2Freflected-redirect%2F#{segment}"
      pattern = Nokizaru::DirRec::Fields.redirect_pattern(url, location)
      pattern.should eq("reflected_path:https:x.com:/locale/{request}")
      Nokizaru::DirRec::Fields.redirect_pattern(url, "#{location}suffix").should eq("path_specific:https:x.com:#{location}suffix")
      Nokizaru::DirRec::Sample.new(302, redirect_pattern: pattern)
    end
    baseline = Nokizaru::DirRec::Soft404.build_from_samples(samples)
    baseline.should_not be_nil
    Nokizaru::DirRec::Confidence.soft_404_match_sample?(samples.last, baseline).should be_true
  end

  it "uses Ruby's nested-path weight at the 200-result ranking cap" do
    target = "https://x.com"
    runtime = Nokizaru::DirRec::Runtime.new(target, target, nil, Nokizaru::DirRec::ConfidenceContext.new(nil, nil))
    responses = (0...200).map { |i| {"#{target}/p#{i}", 302} }
    nested = "#{target}/learning/security"
    responses << {nested, 200}
    responses.each_with_index do |(url, status), index|
      sample = Nokizaru::DirRec::Sample.new(status, content_type: "text/html", body_length: 500)
      runtime.observations << Nokizaru::DirRec::Observation.new(url, status, sample, index + 1, Time.instant)
      runtime.signal_responses << {url, status}
    end
    plan = Nokizaru::DirRec::Plan.build(target, [] of String, "", [] of String)
    info = Nokizaru::DirRec::Target.new(target, target, false, "no-redirect")
    result = Nokizaru::DirRec::Results.assemble(runtime, info, plan, target, 1, false)
    result.prioritized_found.size.should eq(201)
    result.high_signal_found.to_set.should eq(responses.first(200).map(&.[0]).to_set)
    result.high_signal_found.should_not contain(nested)
  end

  it "normalizes many UTF-8 query values with linear allocation growth" do
    urls = {100, 400}.map do |count|
      "https://x.com/search?" + (0...count).map { |i| "v#{i}=caf%C3%A9%26item#{i}" }.join('&')
    end
    reflection_allocations(urls.first)
    small = reflection_allocations(urls.first)
    large = reflection_allocations(urls.last)
    small.should be > 10_000
    (large.to_f / small).should be < 6.0
  end
end
