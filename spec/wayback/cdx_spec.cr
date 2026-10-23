require "../spec_helper"
require "../../src/nokizaru/wayback/cdx"

describe Nokizaru::Wayback::Cdx do
  describe ".parse" do
    it "parses a single-page response with no resume key" do
      body = %q([["timestamp","original","mimetype","statuscode","digest"],["20230101000000","http://x.com/a","text/html","200","AAA"]])
      rows, resume = Nokizaru::Wayback::Cdx.parse(body)
      rows.size.should eq(1)
      rows.first.original.should eq("http://x.com/a")
      rows.first.timestamp.should eq("20230101000000")
      resume.should be_nil
    end

    it "parses a trailing resume key after the separator" do
      body = %q([["timestamp","original","mimetype","statuscode","digest"],["20230101000000","http://x.com/a","text/html","200","AAA"],[],["resumekey123"]])
      rows, resume = Nokizaru::Wayback::Cdx.parse(body)
      rows.size.should eq(1)
      resume.should eq("resumekey123")
    end

    it "rejects a non-array body, a bad timestamp, and data after the separator" do
      expect_raises(Nokizaru::Wayback::Cdx::ParseError) { Nokizaru::Wayback::Cdx.parse("{}") }
      expect_raises(Nokizaru::Wayback::Cdx::ParseError) do
        Nokizaru::Wayback::Cdx.parse(%q([["timestamp","original","mimetype","statuscode","digest"],["bad","http://x.com/a","t","200","d"]]))
      end
      expect_raises(Nokizaru::Wayback::Cdx::ParseError) do
        Nokizaru::Wayback::Cdx.parse(%q([["timestamp","original","mimetype","statuscode","digest"],[],["20230101000000","http://x.com/a","t","200","d"]]))
      end
    end
  end

  describe ".build_payload" do
    it "derives the host and sets the fixed query knobs" do
      payload = Nokizaru::Wayback::Cdx.build_payload("https://Example.COM/path")
      payload["url"].should eq("example.com/")
      payload["matchType"].should eq("host")
      payload["output"].should eq("json")
      payload["showResumeKey"].should eq("true")
      payload["filter"].should start_with("original:")
    end

    it "raises when the target has no hostname" do
      expect_raises(ArgumentError) { Nokizaru::Wayback::Cdx.build_payload("notaurl") }
    end
  end
end
