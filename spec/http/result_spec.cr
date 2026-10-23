require "../spec_helper"
require "../../src/nokizaru/http/result"

describe Nokizaru::Http do
  describe ".classify_error" do
    it "maps a fired deadline to a timeout regardless of the raw exception" do
      kind, message = Nokizaru::Http.classify_error(IO::Error.new("Closed stream"), deadline_hit: true)
      kind.should eq(Nokizaru::Http::ErrorKind::Timeout)
      message.should eq(Nokizaru::Http::TIMEOUT_MESSAGE)
    end

    it "maps a read timeout to a timeout" do
      kind, _ = Nokizaru::Http.classify_error(IO::TimeoutError.new("Read timed out"), deadline_hit: false)
      kind.should eq(Nokizaru::Http::ErrorKind::Timeout)
    end

    it "maps a closed-stream IO error to a closed connection" do
      kind, message = Nokizaru::Http.classify_error(IO::Error.new("Error writing: Broken pipe"), deadline_hit: false)
      kind.should eq(Nokizaru::Http::ErrorKind::Closed)
      message.should contain("dropped the connection")
    end

    it "maps an unrecognized IO error to a generic I/O error" do
      kind, message = Nokizaru::Http.classify_error(IO::Error.new("weird failure"), deadline_hit: false)
      kind.should eq(Nokizaru::Http::ErrorKind::Io)
      message.should contain("weird failure")
    end

    it "classifies known SSL handshake failures by substring" do
      message = Nokizaru::Http.ssl_message("SSL_connect: certificate verify failed")
      message.should eq(Nokizaru::Http::SSL_MESSAGES["certificate verify failed"])
    end

    it "falls back to a generic SSL message for an unknown SSL error" do
      Nokizaru::Http.ssl_message("mystery").should contain("SSL/TLS error")
    end
  end

  describe Nokizaru::Http::Result do
    it "reports success for a response and exposes the status and body" do
      result = Nokizaru::Http::Result.ok(200, HTTP::Headers.new, "body", false)
      result.success?.should be_true
      result.error?.should be_false
      result.status.should eq(200)
      result.body.should eq("body")
      result.truncated?.should be_false
    end

    it "reports an error for a failure and carries the kind and message" do
      result = Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Dns, "no host")
      result.success?.should be_false
      result.error?.should be_true
      result.status.should be_nil
      result.error_kind.should eq(Nokizaru::Http::ErrorKind::Dns)
      result.error_message.should eq("no host")
    end
  end
end
