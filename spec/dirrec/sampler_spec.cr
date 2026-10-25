require "../spec_helper"
require "../../src/nokizaru/dirrec/sampler"
require "../../src/nokizaru/dirrec/soft404"
require "../../src/nokizaru/dirrec/confidence"

describe Nokizaru::DirRec::Sampler do
  it "samples invalid UTF-8 through a valid text view without changing the byte length" do
    body = "<title>binary</title>" + String.new(Bytes[0xff])
    result = Nokizaru::Http::Result.ok(200, HTTP::Headers{"Content-Type" => "text/html"}, body, false)
    sample = Nokizaru::DirRec::Sampler.sample(result, "http://fixture/binary").not_nil!

    sample.title.should eq("binary")
    sample.body_length.should eq(body.bytesize)
    sample.fingerprint.should eq(Nokizaru::DirRec::Fields.body_fingerprint(body.scrub, "http://fixture/binary"))
    result.body.should eq(body)
    result.body.not_nil!.valid_encoding?.should be_false
    sample.body_length.should_not eq(body.scrub.bytesize)

    # Initial probes and runtime learning share the same sampling boundary
    baseline = Nokizaru::DirRec::Soft404.build_from_samples([sample, sample, sample])
    baseline.should_not be_nil
    baseline.not_nil!.body_length.should eq(body.bytesize)
    Nokizaru::DirRec::Confidence.soft_404_match_sample?(sample, baseline).should be_true
  end
end
