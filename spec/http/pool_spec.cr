require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/http/pool"
require "compress/gzip"

private def ok_handler : ::HTTP::Server::Context ->
  ->(context : ::HTTP::Server::Context) do
    case context.request.path
    when "/echo-header"
      context.response.print(context.request.headers["X-Probe"]? || "")
    when "/head"
      context.response.headers["X-Marker"] = "present"
      context.response.print("ignored for head")
    else
      context.response.content_type = "text/plain"
      context.response.print("hello world")
    end
  end
end

describe Nokizaru::Http::Pool do
  it "performs a GET and returns the status, headers, and body" do
    HttpTestServer.with_server(ok_handler) do |base|
      pool = Nokizaru::Http::Pool.new
      result = pool.get("#{base}/")
      result.success?.should be_true
      result.status.should eq(200)
      result.body.should eq("hello world")
      result.headers["Content-Type"].should contain("text/plain")
      pool.shutdown
    end
  end

  it "reuses one connection across sequential requests to the same origin" do
    HttpTestServer.with_server(ok_handler) do |base|
      pool = Nokizaru::Http::Pool.new
      pool.get("#{base}/").success?.should be_true
      pool.get("#{base}/").success?.should be_true
      pool.shutdown
    end
  end

  it "sends merged request headers to the target" do
    HttpTestServer.with_server(ok_handler) do |base|
      pool = Nokizaru::Http::Pool.new
      options = Nokizaru::Http::Options.new(headers: HTTP::Headers{"X-Probe" => "secret"})
      pool.get("#{base}/echo-header", options).body.should eq("secret")
      pool.shutdown
    end
  end

  it "performs a HEAD request" do
    HttpTestServer.with_server(ok_handler) do |base|
      pool = Nokizaru::Http::Pool.new
      result = pool.head("#{base}/head")
      result.success?.should be_true
      result.headers["X-Marker"]?.should eq("present")
      pool.shutdown
    end
  end

  it "caps a gzip bomb at the decoded budget and flags truncation" do
    cap = Nokizaru::Http::BodyCap::MAX_BYTES
    raw = Bytes.new(cap + 4096, 0_u8)
    packed = IO::Memory.new
    Compress::Gzip::Writer.open(packed, &.write(raw))
    payload = packed.to_slice

    bomb = ->(context : ::HTTP::Server::Context) do
      context.response.headers["Content-Encoding"] = "gzip"
      context.response.content_type = "application/octet-stream"
      context.response.write(payload)
    end

    HttpTestServer.with_server(bomb) do |base|
      pool = Nokizaru::Http::Pool.new
      result = pool.get("#{base}/bomb")
      result.success?.should be_true
      result.body.not_nil!.bytesize.should eq(cap)
      result.truncated?.should be_true
      pool.shutdown
    end
  end

  it "classifies a refused connection" do
    port = HttpTestServer.closed_port
    pool = Nokizaru::Http::Pool.new
    result = pool.get("http://127.0.0.1:#{port}/", Nokizaru::Http::Options.new(timeout_s: 2.0))
    result.error?.should be_true
    result.error_kind.should eq(Nokizaru::Http::ErrorKind::ConnectionRefused)
    pool.shutdown
  end

  it "enforces the total operation deadline against a trickling server" do
    trickle = ->(context : ::HTTP::Server::Context) do
      context.response.content_type = "text/plain"
      100.times do
        context.response.print("x")
        context.response.flush
        sleep 0.05.seconds
      end
    end

    HttpTestServer.with_server(trickle) do |base|
      pool = Nokizaru::Http::Pool.new
      result = pool.get("#{base}/slow", Nokizaru::Http::Options.new(timeout_s: 0.3))
      result.error?.should be_true
      result.error_kind.should eq(Nokizaru::Http::ErrorKind::Timeout)
      pool.shutdown
    end
  end

  it "returns a typed failure for a URL with no host" do
    pool = Nokizaru::Http::Pool.new
    pool.get("not-a-url").error?.should be_true
    pool.shutdown
  end

  describe "redirects" do
    private_handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/start"
        context.response.status_code = 302
        context.response.headers["Location"] = "/final"
      when "/final"
        context.response.print("arrived")
      when "/loop"
        context.response.status_code = 302
        context.response.headers["Location"] = "/loop"
      else
        context.response.status_code = 404
      end
    end

    it "follows a same-origin redirect to the final response" do
      HttpTestServer.with_server(private_handler) do |base|
        pool = Nokizaru::Http::Pool.new
        result = pool.get("#{base}/start")
        result.status.should eq(200)
        result.body.should eq("arrived")
        pool.shutdown
      end
    end

    it "does not follow when redirects are disabled" do
      HttpTestServer.with_server(private_handler) do |base|
        pool = Nokizaru::Http::Pool.new
        result = pool.get("#{base}/start", Nokizaru::Http::Options.new(follow_redirects: false))
        result.status.should eq(302)
        pool.shutdown
      end
    end

    it "stops at the redirect budget and returns the last 3xx" do
      HttpTestServer.with_server(private_handler) do |base|
        pool = Nokizaru::Http::Pool.new
        result = pool.get("#{base}/loop", Nokizaru::Http::Options.new(max_redirects: 3))
        result.status.should eq(302)
        pool.shutdown
      end
    end

    it "refuses an out-of-scope redirect and returns the 3xx" do
      out_of_scope = ->(context : ::HTTP::Server::Context) do
        context.response.status_code = 302
        context.response.headers["Location"] = "http://example.com/elsewhere"
      end
      HttpTestServer.with_server(out_of_scope) do |base|
        pool = Nokizaru::Http::Pool.new
        result = pool.get("#{base}/start")
        result.status.should eq(302)
        pool.shutdown
      end
    end

    it "drops operator headers when a redirect changes origin" do
      echo = ->(context : ::HTTP::Server::Context) do
        context.response.print(context.request.headers["X-Secret"]? || "")
      end
      HttpTestServer.with_server(echo) do |echo_base|
        redirector = ->(context : ::HTTP::Server::Context) do
          context.response.status_code = 302
          context.response.headers["Location"] = "#{echo_base}/echo"
        end
        HttpTestServer.with_server(redirector) do |redir_base|
          pool = Nokizaru::Http::Pool.new
          options = Nokizaru::Http::Options.new(headers: HTTP::Headers{"X-Secret" => "leak"})
          result = pool.get("#{redir_base}/start", options)
          result.status.should eq(200)
          result.body.should eq("")
          pool.shutdown
        end
      end
    end

    it "honors an injected restrictive scope predicate" do
      HttpTestServer.with_server(private_handler) do |base|
        pool = Nokizaru::Http::Pool.new
        pool.scope_check = ->(_left : String, _right : String) { false }
        pool.get("#{base}/start").status.should eq(302)
        pool.shutdown
      end
    end
  end
end
