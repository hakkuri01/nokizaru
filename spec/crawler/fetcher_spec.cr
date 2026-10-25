require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/crawler/concurrency"
require "compress/gzip"

describe Nokizaru::Crawler::Fetcher do
  it "keeps redirect scope and drops custom headers on origin changes with worker-local pools" do
    received = [] of String
    echo = ->(context : HTTP::Server::Context) do
      received << (context.request.headers["X-Secret"]? || "")
      context.response.print("arrived")
    end
    HttpTestServer.with_server(echo) do |destination|
      redirect = ->(context : HTTP::Server::Context) do
        received << (context.request.headers["X-Secret"]? || "")
        context.response.status_code = 302
        context.response.headers["Location"] = context.request.path == "/outside" ? "http://example.com/no" : "#{destination}/final"
      end
      HttpTestServer.with_server(redirect) do |base|
        Nokizaru::Crawler::Concurrency.each_concurrently(["#{base}/start"]) do |url, fetcher|
          headers = HTTP::Headers{"X-Secret" => "private"}
          result = fetcher.fetch_following(url, headers)
          result.success?.should be_true
          result.effective_url.should eq("#{destination}/final")
          result.redirect_hops.should eq(1)
          outside = fetcher.fetch_following("#{base}/outside", headers)
          outside.stop_reason.should eq("canonical_handoff")
        end
      end
    end
    received.should eq(["private", "", "private"])
  end

  it "enforces the decoded body cap and can fetch again after truncation" do
    cap = Nokizaru::Http::BodyCap::MAX_BYTES
    packed = IO::Memory.new
    Compress::Gzip::Writer.open(packed, &.write(Bytes.new(cap + 1, 0_u8)))
    requests = 0
    handler = ->(context : HTTP::Server::Context) do
      requests += 1
      if context.request.path == "/bomb"
        context.response.headers["Content-Encoding"] = "gzip"
        context.response.write(packed.to_slice)
      else
        context.response.print("ok")
      end
    end
    HttpTestServer.with_server(handler) do |base|
      Nokizaru::Crawler::Concurrency.each_concurrently(["#{base}/bomb"]) do |url, fetcher|
        result = fetcher.get(url, HTTP::Headers.new, "probe")
        result.truncated?.should be_true
        result.body.not_nil!.bytesize.should eq(cap)
        fetcher.get("#{base}/ok", HTTP::Headers.new, "probe").body.should eq("ok")
      end
    end
    requests.should eq(2)
  end
end
