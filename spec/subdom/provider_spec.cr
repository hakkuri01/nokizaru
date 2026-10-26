require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/subdom/providers"

# A provider pointed at the loopback fixture, exercising the base run/fetch and
# the HTTP-status to health-status mapping without touching the network.
private class LoopbackProvider < Nokizaru::Subdom::Provider
  def initialize(@url : String)
  end

  def name : String
    "Loopback"
  end

  def build(host : String, keys : Hash(String, String)) : Nokizaru::Subdom::Request
    Nokizaru::Subdom::Request.new(@url)
  end

  def parse(host : String, body : String) : Array(String)
    body.lines.compact_map { |line| stripped = line.strip; stripped.empty? ? nil : stripped }
  end
end

private class KeyedProvider < Nokizaru::Subdom::Provider
  def name : String
    "Keyed"
  end

  def key_names : Array({String, String})
    [{"needful", "NK_NEEDFUL_KEY"}]
  end

  def build(host : String, keys : Hash(String, String)) : Nokizaru::Subdom::Request
    Nokizaru::Subdom::Request.new("http://unused.invalid")
  end

  def parse(host : String, body : String) : Array(String)
    [] of String
  end
end

private def status_handler(status : Int32, body : String) : ::HTTP::Server::Context ->
  ->(ctx : ::HTTP::Server::Context) do
    ctx.response.status_code = status
    ctx.response.print(body)
    nil
  end
end

describe Nokizaru::Subdom::Provider do
  describe "#run status mapping" do
    it "is healthy and returns parsed names on 200" do
      HttpTestServer.with_server(status_handler(200, "a.example.com\nb.example.com\n")) do |base|
        outcome = LoopbackProvider.new(base).run("example.com", Nokizaru::Http::Pool.new, {} of String => String, 5.0)

        outcome.status.should eq("healthy")
        outcome.names.should eq(["a.example.com", "b.example.com"])
        outcome.result_count.should eq(2)
        outcome.elapsed_s.not_nil!.should be >= 0.0
      end
    end

    it "is error on a 500" do
      HttpTestServer.with_server(status_handler(500, "boom")) do |base|
        LoopbackProvider.new(base).run("example.com", Nokizaru::Http::Pool.new, {} of String => String, 5.0).status.should eq("error")
      end
    end

    it "is rate_limited on a 429" do
      HttpTestServer.with_server(status_handler(429, "")) do |base|
        LoopbackProvider.new(base).run("example.com", Nokizaru::Http::Pool.new, {} of String => String, 5.0).status.should eq("rate_limited")
      end
    end

    it "skips without making a request when a key is missing" do
      outcome = KeyedProvider.new.run("example.com", Nokizaru::Http::Pool.new, {} of String => String, 5.0)
      outcome.status.should eq("skipped")
      outcome.reason.should eq("API key not found!")
    end
  end

  describe "provider parsing" do
    it "AnubisDB reads a JSON array" do
      Nokizaru::Subdom::AnubisDB.new.parse("example.com", %q(["a.example.com","b.example.com"])).should eq(["a.example.com", "b.example.com"])
    end

    it "crt.sh splits newline-joined name_value fields" do
      body = %q([{"name_value":"a.example.com\nb.example.com"},{"name_value":"c.example.com"}])
      Nokizaru::Subdom::CrtSh.new.parse("example.com", body).should eq(["a.example.com", "b.example.com", "c.example.com"])
    end

    it "HackerTarget takes the host from each CSV line" do
      Nokizaru::Subdom::HackerTarget.new.parse("example.com", "a.example.com,1.2.3.4\nb.example.com,5.6.7.8\n").should eq(["a.example.com", "b.example.com"])
    end

    it "Shodan qualifies labels with the host" do
      Nokizaru::Subdom::Shodan.new.parse("example.com", %q({"subdomains":["www","mail"]})).should eq(["www.example.com", "mail.example.com"])
    end

    it "CertSpotter flattens dns_names" do
      Nokizaru::Subdom::CertSpotter.new.parse("example.com", %q([{"dns_names":["a.example.com","b.example.com"]}])).should eq(["a.example.com", "b.example.com"])
    end

    it "Censys reads certificate names" do
      body = %q({"result":{"hits":[{"names":["A.example.com","b.invalid"]}]}})
      Nokizaru::Subdom::Censys.new.parse("example.com", body).should eq(["a.example.com"])
    end

    it "SecurityTrails qualifies labels with the host" do
      Nokizaru::Subdom::SecurityTrails.new.parse("example.com", %q({"subdomains":["www","mail"]})).should eq(["www.example.com", "mail.example.com"])
    end

    it "extracts in-scope hosts from arbitrary text (Wayback URLs)" do
      body = "http://a.example.com/x\nhttps://b.example.com:443/y\nhttp://evil.com/example.com\n"
      Nokizaru::Subdom::WaybackArchive.new.parse("example.com", body).sort.should eq(["a.example.com", "b.example.com"])
    end

    it "extracts hosts mentioned in source code (GitHub match text)" do
      body = %q({"items":[{"text_matches":[{"fragment":"host: api.example.com and cdn.example.com"}]}]})
      Nokizaru::Subdom::Github.new.parse("example.com", body).sort.should eq(["api.example.com", "cdn.example.com"])
    end
  end

  describe "request building" do
    it "HackerTarget puts the host in the q parameter" do
      Nokizaru::Subdom::HackerTarget.new.build("example.com", {} of String => String).url.should contain("q=example.com")
    end

    it "SecurityTrails carries the APIKEY header" do
      request = Nokizaru::Subdom::SecurityTrails.new.build("example.com", {"securitytrails" => "k"})
      request.headers["APIKEY"].should eq("k")
    end

    it "GitHub authorizes with a token" do
      request = Nokizaru::Subdom::Github.new.build("example.com", {"github" => "tok"})
      request.headers["Authorization"].should eq("token tok")
    end

    it "Censys starts with an empty cursor" do
      keys = {"censys_api_id" => "id", "censys_api_secret" => "secret"}
      request = Nokizaru::Subdom::Censys.new.build("example.com", keys)
      JSON.parse(request.body.not_nil!)["cursor"].as_s.should eq("")
    end
  end
end
