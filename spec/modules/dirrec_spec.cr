require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/modules/dirrec"
require "../../src/nokizaru/findings/directory_rules"
require "../../src/nokizaru/context"

private GENERIC = "<html><title>welcome</title><body>default landing</body></html>"
private ADMIN   = "<html><title>admin dashboard</title><body>#{"administration console user management settings panel audit logs roles permissions sessions " * 3}</body></html>"
private CONFIG  = "<html><title>config</title><body>#{"application configuration environment variables secrets datastore endpoints feature flags toggles " * 3}</body></html>"

private def dir_handler(context : ::HTTP::Server::Context)
  context.response.content_type = "text/html"
  case context.request.path
  when "/admin"  then context.response.print(ADMIN)
  when "/config" then context.response.print(CONFIG)
  else                context.response.print(GENERIC)
  end
end

describe Nokizaru::Modules::DirectoryEnum do
  it "enumerates paths, learns the soft-404 wildcard, and classifies by confidence" do
    wordlist = File.tempname("nok-dir", ".txt")
    File.write(wordlist, "admin\nconfig\nsecret\n")

    begin
      handler = ->(context : ::HTTP::Server::Context) { dir_handler(context) }
      HttpTestServer.with_server(handler) do |base|
        config = Nokizaru::Modules::DirectoryEnum::Config.new(wordlist: wordlist, threads: 4, timeout_s: 3.0)
        reports = [] of String
        progress = Nokizaru::ProgressReporter.new(->(_stage : String, detail : String) { reports << detail; nil })
        result = Nokizaru::Modules::DirectoryEnum.collect("#{base}/", config, progress)

        # live rail detail, e.g. "3/8 avg 12.5r/s ok 3 err 0 found 2"
        reports.any?(&.matches?(/\A\d+\/\d+ avg [\d.]+r\/s ok \d+ err \d+ found \d+\z/)).should be_true

        result.target.original.should eq("#{base}/")
        result.stats.mode.should eq("full")
        result.stats.adaptive_concurrency.should eq(4)
        result.stats.successful.should be > 0

        result.confirmed_found.any?(&.ends_with?("/admin")).should be_true
        result.prioritized_found.any?(&.ends_with?("/admin")).should be_true
        # /config is meaningful but not a high-signal path, so it is prioritized (likely), not confirmed
        result.prioritized_found.any?(&.ends_with?("/config")).should be_true
        # /secret returns the wildcard page, so it is a soft-404 match → low confidence
        result.low_confidence_found.any?(&.ends_with?("/secret")).should be_true
        result.by_status["200"]?.should_not be_nil

        finding = Nokizaru::Findings::DirectoryRules.call(result)
        finding.size.should eq(1)
        finding.first.id.should eq("dir.interesting_paths")
      end
    ensure
      File.delete(wordlist) rescue nil
    end
  end

  it "stores the typed result on the run" do
    run = Nokizaru::RunState.new(Nokizaru::Meta.new(version: "1.0.0", target: "x", started_at: "t"))
    info = Nokizaru::DirRec::Target.new(original: "http://x", effective: "http://x", reanchored: false, reason: "")
    run.modules.directory_enum = Nokizaru::DirRec::Result.new(info)
    run.modules.directory_enum.should_not be_nil
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

describe "Nokizaru::Modules::DirectoryEnum.present" do
  it "renders status-colored findings and a summary" do
    info = Nokizaru::DirRec::Target.new(original: "http://x/", effective: "http://x/", reanchored: false, reason: "")
    result = Nokizaru::DirRec::Result.new(info)
    result.stdout_found = ["http://x/admin", "http://x/config"]
    result.found = ["http://x/admin", "http://x/config"]
    result.low_confidence_found = ["http://x/secret"]
    result.by_status = {"200" => ["http://x/admin"], "403" => ["http://x/config"]}
    result.stats.requests_per_second = 45.2

    text = present_capture { Nokizaru::Modules::DirectoryEnum.present(result) }

    text.should contain("200")
    text.should contain("http://x/admin")
    text.should contain("403")
    text.should contain("http://x/config")
    text.should contain("Requests/second")
    text.should contain("45.2")
    text.should contain("Directories found")
    text.should contain("Low confidence")
  end
end
