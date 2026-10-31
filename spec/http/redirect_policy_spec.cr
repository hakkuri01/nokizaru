require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/http/pool"

private def with_redirect_routes(routes : Hash(String, String), &block : Nokizaru::Http::Pool, Array(Tuple(String, HTTP::Headers)), Array(String) ->)
  requests = [] of Tuple(String, HTTP::Headers)
  origins = [] of String
  handler = ->(context : HTTP::Server::Context) do
    path = context.request.path
    requests << {context.request.resource, context.request.headers.dup}
    if location = routes[path]?
      context.response.status_code = 302
      context.response.headers["Location"] = location
    else
      context.response.print("arrived")
    end
  end
  HttpTestServer.with_server(handler) do |base|
    port = URI.parse(base).port.not_nil!
    factory = ->(host : String, target_port : Int32, tls : Bool, verify : Bool) do
      origins << "#{tls ? "https" : "http"}://#{host}:#{target_port}"
      Nokizaru::Http::Client.new("127.0.0.1", port, false, verify)
    end
    pool = Nokizaru::Http::Pool.new(client_factory: factory)
    begin
      block.call(pool, requests, origins)
    ensure
      pool.shutdown
    end
  end
end

private def redirect_credentials
  HTTP::Headers{"Authorization" => "Bearer secret", "Cookie" => "session=secret", "X-Secret" => "secret"}
end

describe "Shared redirect policy" do
  it "retains same-origin credentials then drops them permanently across sibling and return hops" do
    routes = {
      "/start"   => "/same",
      "/same"    => "http://b.example.com/sibling",
      "/sibling" => "http://c.example.com/next",
      "/next"    => "/still",
      "/still"   => "http://a.example.com/return",
    }
    with_redirect_routes(routes) do |pool, requests, origins|
      headers = redirect_credentials
      options = Nokizaru::Http::Options.new(headers: headers, scope_check: Nokizaru::TargetIntel.scope_check)
      pool.get("http://a.example.com/start", options).status.should eq(200)
      requests.map(&.[0]).should eq(["/start", "/same", "/sibling", "/next", "/still", "/return"])
      requests.first(2).each do |_, sent|
        headers.each { |name, values| sent[name].should eq(values.join(", ")) }
      end
      requests.skip(2).each do |_, sent|
        headers.each { |name, _| sent.has_key?(name).should be_false }
      end
      headers.should eq(redirect_credentials)
      origins.should eq(["http://a.example.com:80", "http://b.example.com:80", "http://c.example.com:80"])
    end
  end

  it "keeps sibling redirects opt-in for other modules" do
    with_redirect_routes({"/start" => "http://b.example.com/forbidden"}) do |pool, requests, origins|
      pool.get("http://a.example.com/start").status.should eq(302)
      requests.map(&.[0]).should eq(["/start"])
      origins.should eq(["http://a.example.com:80"])
    end
  end

  it "preserves valid escaped path and query bytes" do
    target = "/valid%2Fpath?value=%20"
    with_redirect_routes({"/start" => target}) do |pool, requests, _origins|
      pool.get("http://a.example.com/start").status.should eq(200)
      requests.map(&.[0]).should eq(["/start", target])
    end
  end

  {
    "out of scope" => "https://elsewhere.net/forbidden",
    "downgrade"    => "http://a.example.com/forbidden",
    "userinfo"     => "https://user:secret@a.example.com/forbidden",
    "scheme"       => "file:///forbidden",
    "backslash"    => "/bad\\path",
    "space"        => "/bad path",
    "escape"       => "/bad%zz",
    "short escape" => "/bad%2",
    "zero port"    => "https://a.example.com:0/forbidden",
    "large port"   => "https://a.example.com:65536/forbidden",
  }.each do |reason, location|
    it "refuses #{reason} without another request" do
      with_redirect_routes({"/start" => location}) do |pool, requests, origins|
        options = Nokizaru::Http::Options.new(scope_check: Nokizaru::TargetIntel.scope_check)
        pool.get("https://a.example.com/start", options).status.should eq(302)
        requests.map(&.[0]).should eq(["/start"])
        origins.should eq(["https://a.example.com:443"])
      end
    end
  end

  it "makes exactly the initial request plus the configured hop budget" do
    with_redirect_routes({"/loop" => "/loop"}) do |pool, requests, _origins|
      options = Nokizaru::Http::Options.new(max_redirects: 2)
      pool.get("http://a.example.com/loop", options).status.should eq(302)
      requests.map(&.[0]).should eq(["/loop"] * 3)
    end
  end

  it "preserves every option when replacing headers" do
    scope = Nokizaru::TargetIntel.scope_check
    options = Nokizaru::Http::Options.new(headers: redirect_credentials, timeout_s: 2.0,
      follow_redirects: false, max_redirects: 2, body: "payload", scope_check: scope)
    copy = options.with_headers(HTTP::Headers.new)
    copy.headers.empty?.should be_true
    copy.timeout_s.should eq(2.0)
    copy.follow_redirects?.should be_false
    copy.max_redirects.should eq(2)
    copy.body.should eq("payload")
    copy.scope_check.should eq(scope)
  end
end
