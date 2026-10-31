require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/links"

describe Nokizaru::Crawler::Links do
  it "parses a robots line padded with a long whitespace run" do
    # robots.txt is target-controlled text read up to the body cap, and a lazy
    # capture before a trailing \s* backtracks quadratically over a run of
    # spaces, so the evidence here is that the call returns at all: the earlier
    # pattern needed about 40 s for this line.
    padded = "Disallow: /admin#{" " * 200_000}\nSitemap: /sitemap-a.xml\n"
    handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/robots.txt" then context.response.print(padded)
      else                    context.response.status_code = 404
      end
    end

    HttpTestServer.with_server(handler) do |base|
      links = Nokizaru::Crawler::Links.new(
        Nokizaru::Crawler::Fetcher.new(Nokizaru::Http::Pool.new),
        ::HTTP::Headers.new,
        Nokizaru::Crawler::Budget.new,
      )
      page = links.extract(XML.parse_html("<html><body></body></html>"), "#{base}/", base)
      page.robots_links.should eq(["#{base}/admin", "#{base}/sitemap-a.xml"])
      page.sitemap_links.should eq(["#{base}/sitemap-a.xml"])
    end
  end

  it "reads a directive regardless of spacing and skips anything else" do
    handler = ->(context : ::HTTP::Server::Context) do
      case context.request.path
      when "/robots.txt"
        context.response.print("User-agent: *\n# Disallow: /commented\n  Allow : /ok\nnonsense\n")
      else
        context.response.status_code = 404
      end
    end

    HttpTestServer.with_server(handler) do |base|
      links = Nokizaru::Crawler::Links.new(
        Nokizaru::Crawler::Fetcher.new(Nokizaru::Http::Pool.new),
        ::HTTP::Headers.new,
        Nokizaru::Crawler::Budget.new,
      )
      page = links.extract(XML.parse_html("<html></html>"), "#{base}/", base)
      page.robots_links.should eq(["#{base}/ok"])
    end
  end
end
