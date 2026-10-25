require "../spec_helper"
require "../../src/nokizaru/findings/adversary_rules"

private def dir_result(by_status : Hash(String, Int32)) : Nokizaru::DirRec::Result
  target = Nokizaru::DirRec::Target.new(original: "https://x.com", effective: "https://x.com", reanchored: false, reason: "")
  result = Nokizaru::DirRec::Result.new(target)
  result.by_status = by_status.transform_values { |count| Array.new(count, "https://x.com/p") }
  result
end

private def headers_with(map : Hash(String, String)) : Nokizaru::Modules::Headers::Result
  profile = Nokizaru::TargetIntel::Profile.new("https://x.com", "https://x.com", "none", "low", "r")
  Nokizaru::Modules::Headers::Result.ok(map, profile)
end

describe Nokizaru::Findings::AdversaryRules do
  it "names a WAF and its vendor from a dominant block shape plus an edge header" do
    result = dir_result({"403" => 300, "200" => 3})
    findings = Nokizaru::Findings::AdversaryRules.call(result, headers_with({"Server" => "cloudflare"}))
    findings.size.should eq(1)
    findings.first.id.should eq("dir.waf_detected")
    findings.first.title.should contain("Cloudflare")
    findings.first.evidence.not_nil!.should contain("HTTP 403")
  end

  it "names a WAF from the likelihood signal even with no edge header" do
    result = dir_result({"403" => 200})
    result.stats.waf_likelihood_score = 0.6
    Nokizaru::Findings::AdversaryRules.call(result).first.id.should eq("dir.waf_detected")
  end

  it "names rate-limiting, a soft-404 wildcard, and an auth wall" do
    Nokizaru::Findings::AdversaryRules.call(dir_result({"429" => 200})).first.id.should eq("dir.rate_limited")

    spa = dir_result({"200" => 200})
    spa.stats.soft_404_dominance_ratio = 1.0
    Nokizaru::Findings::AdversaryRules.call(spa).first.id.should eq("dir.soft_404_wildcard")

    wall = dir_result({"302" => 200})
    wall.stats.redirect_cluster_dominance_ratio = 1.0
    Nokizaru::Findings::AdversaryRules.call(wall).first.id.should eq("dir.auth_wall")
  end

  it "does not flag a benign site that merely returns many honest 404s" do
    Nokizaru::Findings::AdversaryRules.call(dir_result({"404" => 500, "200" => 20})).should be_empty
  end

  it "stays silent below the minimum sample size" do
    result = dir_result({"403" => 10})
    result.stats.waf_likelihood_score = 0.9
    Nokizaru::Findings::AdversaryRules.call(result).should be_empty
  end
end
