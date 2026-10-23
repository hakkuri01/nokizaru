require "./spec_helper"
require "../src/nokizaru/request_headers"

private alias RequestHeaders = Nokizaru::RequestHeaders

describe Nokizaru::RequestHeaders do
  it "parses Name: Value headers and trims leading value whitespace" do
    headers = RequestHeaders.parse(["Authorization: Bearer token", "X-Test:  spaced"])
    headers["Authorization"].should eq("Bearer token")
    headers["X-Test"].should eq("spaced")
  end

  it "rejects malformed headers" do
    expect_raises(ArgumentError) { RequestHeaders.parse(["no-colon"]) }
    expect_raises(ArgumentError) { RequestHeaders.parse([""]) }
    expect_raises(ArgumentError) { RequestHeaders.parse(["X: a\r\nInjected: b"]) }
    expect_raises(ArgumentError) { RequestHeaders.parse(["Bad Name: value"]) }
  end
end
