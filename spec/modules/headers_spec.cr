require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/modules/headers"

describe Nokizaru::Modules::Headers do
  it "redacts a credential the target echoes back into a response header" do
    handler = ->(context : ::HTTP::Server::Context) do
      # An ordinary session refresh is enough: the value the operator supplied
      # comes back in a response header that stdout and every export would carry.
      context.response.headers["Set-Cookie"] = context.request.headers["Cookie"]? || ""
      context.response.print("hi")
    end
    HttpTestServer.with_server(handler) do |base|
      supplied = ::HTTP::Headers{"Cookie" => "PHPSESSID=s3cr3t-operator-value"}
      result = Nokizaru::Modules::Headers.collect("#{base}/", Nokizaru::Http::Pool.new, supplied)
      result.success?.should be_true
      result.headers["set-cookie"].should eq("[redacted]")
      result.headers.values.any?(&.includes?("s3cr3t-operator-value")).should be_false
    end
  end

  it "strips a bidi override from a header value before storing it" do
    handler = ->(context : ::HTTP::Server::Context) do
      # A control byte cannot travel in a real header value (the server refuses
      # it), but a bidi override can, and it would reverse text in a report file.
      context.response.headers["X-Hostile"] = "ok\u202ereversed"
      context.response.print("hi")
    end
    HttpTestServer.with_server(handler) do |base|
      result = Nokizaru::Modules::Headers.collect("#{base}/", Nokizaru::Http::Pool.new)
      result.headers["x-hostile"].should eq("okreversed")
    end
  end

  it "collects lowercased headers and a no-redirect profile" do
    handler = ->(context : ::HTTP::Server::Context) do
      context.response.headers["X-Frame-Options"] = "DENY"
      context.response.print("hi")
    end
    HttpTestServer.with_server(handler) do |base|
      result = Nokizaru::Modules::Headers.collect("#{base}/", Nokizaru::Http::Pool.new)
      result.success?.should be_true
      result.headers["x-frame-options"].should eq("DENY")
      result.target_profile.mode.should eq("none")
      result.target_profile.original_url.should eq("#{base}/")
    end
  end

  it "does not follow redirects and records a same-scope profile" do
    handler = ->(context : ::HTTP::Server::Context) do
      if context.request.path == "/start"
        context.response.status_code = 302
        context.response.headers["Location"] = "/landing"
      else
        context.response.print("landed")
      end
    end
    HttpTestServer.with_server(handler) do |base|
      result = Nokizaru::Modules::Headers.collect("#{base}/start", Nokizaru::Http::Pool.new)
      result.success?.should be_true
      result.target_profile.mode.should eq("same_scope_redirect")
      result.target_profile.location.not_nil!.should end_with("/landing")
      result.target_profile.effective_url.should_not be_empty
    end
  end

  it "returns a failure result with a profile when the fetch fails" do
    result = Nokizaru::Modules::Headers.collect(
      "http://127.0.0.1:#{HttpTestServer.closed_port}/", Nokizaru::Http::Pool.new
    )
    result.success?.should be_false
    result.error.should_not be_nil
    result.target_profile.mode.should eq("none")
  end
end

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

describe "Nokizaru::Modules::Headers.present" do
  it "renders headers as rows and breaks a long Set-Cookie into a tree" do
    long_cookie = "sid=#{"a" * 150}; Path=/; Expires=Wed, 09 Jun 2027 10:18:14 GMT, id=2; Secure"
    result = Nokizaru::Modules::Headers::Result.ok(
      {"server" => "nginx", "set-cookie" => long_cookie},
      Nokizaru::TargetIntel.profile("https://example.com", nil))
    text = present_capture { Nokizaru::Modules::Headers.present(result) }
    text.should contain("server")
    text.should contain("nginx")
    text.should contain("cookie")
    text.should contain("id=2")
  end

  it "renders an SSL error" do
    result = Nokizaru::Modules::Headers::Result.failure(
      "handshake failed", Nokizaru::TargetIntel.profile("https://example.com", nil), "SSLError")
    present_capture { Nokizaru::Modules::Headers.present(result) }.should contain("SSL Error")
  end
end

describe "Nokizaru::Modules::Headers.split_set_cookie" do
  it "keeps Expires-date commas inside one cookie" do
    cookies = Nokizaru::Modules::Headers.split_set_cookie(
      "a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2; Secure")
    cookies.size.should eq(2)
    cookies[0].should contain("Expires=Wed, 09 Jun 2027")
    cookies[1].should contain("b=2")
  end
end
