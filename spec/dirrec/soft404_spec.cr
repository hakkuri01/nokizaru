require "../spec_helper"
require "../../src/nokizaru/dirrec/soft404"

private def content_sample(length = 100, fingerprint = "abc")
  Nokizaru::DirRec::Sample.new(200, content_type: "text/html", body_length: length, title: "hi", fingerprint: fingerprint)
end

describe Nokizaru::DirRec::Soft404 do
  it "builds a content baseline from homogeneous probes" do
    baseline = Nokizaru::DirRec::Soft404.build_from_samples([content_sample, content_sample, content_sample])
    baseline.should_not be_nil
    baseline.not_nil!.status.should eq(200)
    baseline.not_nil!.content_type.should eq("text/html")
    baseline.not_nil!.fingerprint.should eq("abc")
    baseline.not_nil!.tolerance.not_nil!.should be >= Nokizaru::DirRec::SOFT_404_MIN_TOLERANCE
  end

  it "returns no baseline when probes disagree on status" do
    mixed = [content_sample, Nokizaru::DirRec::Sample.new(301, location: "http://x/other")]
    Nokizaru::DirRec::Soft404.build_from_samples(mixed).should be_nil
  end

  it "learns a baseline from a dominant live signature" do
    learning = Nokizaru::DirRec::Soft404::Learning.new
    baseline = nil
    10.times { baseline = Nokizaru::DirRec::Soft404.learn(content_sample(200, "dom"), baseline, learning) }
    baseline.should_not be_nil
    baseline.not_nil!.fingerprint.should eq("dom")
  end

  it "tracks learning state and disables on an unstable surface" do
    state = Nokizaru::DirRec::Soft404::State.new
    Nokizaru::DirRec::Soft404.soft_404_active?(state, nil).should be_true

    learning = Nokizaru::DirRec::Soft404::Learning.new
    30.times do |i|
      Nokizaru::DirRec::Soft404.learn(content_sample(i * 300, "fp#{i}"), nil, learning)
      Nokizaru::DirRec::Soft404.record_sample!(state)
    end
    Nokizaru::DirRec::Soft404.disable_if_unstable!(state, nil, learning)
    state.enabled?.should be_false
  end
end
