require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/modules/dirrec"

describe "Directory redirect options" do
  {true, false}.each do |follow|
    it "#{follow ? "follows" : "refuses"} redirects with custom headers for workers and soft-404 probes" do
      requests = [] of Tuple(String, String?)
      handler = ->(context : HTTP::Server::Context) do
        requests << {context.request.path, context.request.headers["Authorization"]?}
        context.response.content_type = "text/html"
        if context.request.path == "/landing"
          context.response.status_code = 404
          context.response.print("missing")
        else
          context.response.status_code = 302
          context.response.headers["Location"] = "/landing"
        end
      end
      wordlist = File.tempname("nok-redirect", ".txt")
      begin
        File.write(wordlist, "candidate\n")
        HttpTestServer.with_server(handler) do |base|
          profile = Nokizaru::TargetIntel::Profile.new(base, base, "none", "low", "No redirect")
          config = Nokizaru::Modules::DirectoryEnum::Config.new(wordlist: wordlist, threads: 1,
            allow_redirects: follow, request_headers: HTTP::Headers{"Authorization" => "Bearer secret"}, profile: profile)
          result = Nokizaru::Modules::DirectoryEnum.collect(base, config)
          initial = result.stats.total_requests + Nokizaru::DirRec::SOFT_404_PROBES
          requests.count { |path, _| path != "/landing" }.should eq(initial)
          requests.count { |path, _| path == "/landing" }.should eq(follow ? initial : 0)
          requests.size.should eq(initial * (follow ? 2 : 1))
          requests.each { |_, authorization| authorization.should eq("Bearer secret") }
        end
      ensure
        File.delete(wordlist) if File.exists?(wordlist)
      end
    end
  end

  it "preserves all request options when the runtime adapts the timeout" do
    received = [] of Nokizaru::Http::Options
    transport = ->(_url : String, options : Nokizaru::Http::Options) do
      received << options
      Nokizaru::Http::Result.ok(404, HTTP::Headers.new, "missing", false)
    end
    scope = Nokizaru::TargetIntel.scope_check
    headers = HTTP::Headers{"Authorization" => "Bearer secret"}
    options = Nokizaru::Http::Options.new(headers: headers, timeout_s: 12.0,
      follow_redirects: true, max_redirects: 2, body: "payload", scope_check: scope)
    runtime = Nokizaru::DirRec::Runtime.new("http://a.example.com", "http://a.example.com", nil,
      Nokizaru::DirRec::ConfidenceContext.new(nil, nil), transport: transport)
    plan = Nokizaru::DirRec::UrlPlan.new([] of String, [] of String, ["candidate"], [] of String, 1)
    runtime.run(Nokizaru::DirRec::LazyQueue.new(plan, "http://a.example.com"), 1, options)
    received.size.should eq(1)
    copy = received.first
    copy.headers.should eq(headers)
    copy.timeout_s.should eq(runtime.policy.timeout_s)
    copy.follow_redirects?.should be_true
    copy.max_redirects.should eq(2)
    copy.body.should eq("payload")
    copy.scope_check.should eq(scope)
  end
end
