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

  it "keeps the operator's headers off a seed on another origin and refetches nothing" do
    counts = Hash(String, Int32).new(0)
    page = ->(ctx : ::HTTP::Server::Context) do
      counts["page#{ctx.request.path}"] += 1
      counts["page-cookie"] += 1 if ctx.request.headers["Cookie"]?
      ctx.response.print(%(<html><body><a href="/about">about</a></body></html>))
    end

    HttpTestServer.with_server(page) do |base|
      sibling = ->(ctx : ::HTTP::Server::Context) do
        counts["seed#{ctx.request.path}"] += 1
        counts["seed-cookie"] += 1 if ctx.request.headers["Cookie"]?
        ctx.response.print(%(<html><body><a href="/legacy/child">child</a></body></html>))
      end

      HttpTestServer.with_server(sibling) do |seed_base|
        profile = Nokizaru::TargetIntel::Profile.new(base, base, "none", "low", "r")
        headers = ::HTTP::Headers{"Cookie" => "session=operator-secret"}
        result = Nokizaru::Crawler::Engine.new(Nokizaru::Http::Pool.new, headers, ["#{seed_base}/legacy"])
          .run(base, profile)

        result.internal_links.should contain("#{seed_base}/legacy")
        # The seed is in scope (same host) but another origin, so it is fetched
        # without the operator's cookie.
        counts["page-cookie"].should eq(3) # landing page, robots.txt, sitemap.xml
        counts["seed-cookie"].should eq(0)
        # robots.txt and sitemap.xml belong to the landing page; a seed must not
        # fetch either one again.
        counts["page/robots.txt"].should eq(1)
        counts["page/sitemap.xml"].should eq(1)
        counts["seed/robots.txt"].should eq(0)
        counts["seed/sitemap.xml"].should eq(0)
      end
    end
  end
end
