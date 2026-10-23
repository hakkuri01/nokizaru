require "./spec_helper"
require "json"
require "../src/nokizaru/context"

private def meta
  Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-10-20T00:00:00Z")
end

describe Nokizaru::RunState do
  it "serializes to the Ruby run shape: meta, modules, artifacts, findings" do
    run = Nokizaru::RunState.new(meta)
    run.add_artifact("subdomains", ["a.example.com", "a.example.com", "b.example.com"])
    json = JSON.parse(run.to_json)

    json["meta"]["target"].as_s.should eq("https://example.com")
    json["modules"].as_h.empty?.should be_true
    json["artifacts"]["subdomains"].as_a.map(&.as_s).should eq(["a.example.com", "b.example.com"])
    json["findings"].as_a.empty?.should be_true
  end

  it "dedups artifacts while preserving first-seen order" do
    run = Nokizaru::RunState.new(meta)
    run.add_artifact("k", ["b", "a", "b", "a", "c"])
    run.artifacts["k"].should eq(["b", "a", "c"])
  end

  it "keeps unresolved hostname and ip as null in meta, like the Ruby tool" do
    json = JSON.parse(meta.to_json)
    json.as_h.has_key?("hostname").should be_true
    json["hostname"].raw.should be_nil
    json.as_h.has_key?("ip").should be_true
  end
end

describe Nokizaru::Finding do
  it "serializes the module and tags keys exactly" do
    finding = Nokizaru::Finding.new(
      id: "headers.missing_content_security_policy",
      severity: "medium",
      title: "CSP header missing",
      source_module: "headers",
      tags: ["headers", "posture"],
      evidence: "Response did not include content-security-policy",
      recommendation: "Add a Content-Security-Policy.",
    )
    json = JSON.parse(finding.to_json)
    json["id"].as_s.should eq("headers.missing_content_security_policy")
    json["module"].as_s.should eq("headers")
    json["tags"].as_a.map(&.as_s).should eq(["headers", "posture"])
    json["evidence"].as_s.should contain("content-security-policy")
  end

  it "omits an unset optional field" do
    finding = Nokizaru::Finding.new(id: "x", severity: "low", title: "t", source_module: "m", tags: [] of String)
    JSON.parse(finding.to_json).as_h.has_key?("evidence").should be_false
  end
end

describe Nokizaru::Context do
  it "delegates artifact collection to the shared run state" do
    ctx = Nokizaru::Context.new(Nokizaru::RunState.new(meta))
    ctx.add_artifact("hosts", ["x.example.com"])
    ctx.run.artifacts["hosts"].should eq(["x.example.com"])
  end
end
