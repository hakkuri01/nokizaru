require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/engine"

describe Nokizaru::Crawler::JavaScript do
  it "extracts both absolute and root-relative endpoint paths from script bodies" do
    app_js = <<-JS
      fetch("/api/v1/users").then(r => r.json());
      fetch("/api/v2/orders").then(r => r.json());
      fetch("http://HOST/api/v1/session").then(r => r.json());
      JS
    handler = ->(ctx : ::HTTP::Server::Context) do
      case ctx.request.path
      when "/"
        ctx.response.content_type = "text/html"
        ctx.response.print(%(<html><body><script src="/app.js"></script></body></html>))
      when "/app.js"
        ctx.response.content_type = "application/javascript"
        # the absolute URL self-references this server so it stays in scope
        ctx.response.print(app_js.sub("HOST", "#{ctx.request.headers["Host"]?}"))
      else
        ctx.response.print("x")
      end
    end

    HttpTestServer.with_server(handler) do |base|
      profile = Nokizaru::TargetIntel::Profile.new(base, base, "none", "low", "r")
      pool = Nokizaru::Http::Pool.new
      result = Nokizaru::Crawler::Engine.new(pool, ::HTTP::Headers.new).run(base, profile)
      js = result.urls_inside_js
      # the relative paths are the regression target: before the fix only the
      # absolute /api/v1/session came through.
      js.should contain("#{base}/api/v1/users")
      js.should contain("#{base}/api/v2/orders")
      js.should contain("#{base}/api/v1/session")
    end
  end
end
