require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/engine"

describe Nokizaru::Crawler::Engine do
  it "crawls wayback-seeded historic URLs the current link graph omits" do
    handler = ->(ctx : ::HTTP::Server::Context) do
      case ctx.request.path
      when "/"       then ctx.response.print(%(<html><body><a href="/about">about</a></body></html>))
      when "/legacy" then ctx.response.print(%(<html><body><a href="/legacy/child">child</a></body></html>))
      else                ctx.response.print(%(<html><body>page</body></html>))
      end
    end

    HttpTestServer.with_server(handler) do |base|
      profile = Nokizaru::TargetIntel::Profile.new(base, base, "none", "low", "r")
      pool = Nokizaru::Http::Pool.new
      # "/legacy" is not linked from "/", so a plain crawl never reaches it; only
      # the wayback seed does.
      result = Nokizaru::Crawler::Engine.new(pool, ::HTTP::Headers.new, ["#{base}/legacy"]).run(base, profile)
      result.internal_links.should contain("#{base}/legacy")
    end
  end
end
