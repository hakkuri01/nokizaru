require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/cli/workflow"

private alias Workflow = Nokizaru::CLI::Workflow
private alias Options = Nokizaru::CLI::Options

private STUB = ->(_host : String) { "127.0.0.1".as(String?) }

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

# Runs a block with the UI sink muted, returning the block's value. Used for
# setup (plan!) whose rendered output a test does not assert on.
private def silence(&block : -> T) : T forall T
  Nokizaru::UI.output = IO::Memory.new
  block.call
ensure
  Nokizaru::UI.output = STDOUT
end

private def scan_options(base : String, wordlist : String) : Options
  opts = Options.new
  opts.target = base
  opts.modules << "headers"
  opts.modules << "crawl"
  opts.modules << "dir"
  opts.wordlist = wordlist
  opts.timeout = 5.0
  opts
end

private def scan_handler(context : ::HTTP::Server::Context)
  context.response.content_type = "text/html"
  case context.request.path
  when "/"           then context.response.print(%(<html><body><a href="/admin">a</a></body></html>))
  when "/robots.txt" then context.response.print("User-agent: *\nDisallow: /secret\n")
  when "/admin"      then context.response.print(%(<html><title>admin</title><body>#{"admin console users roles settings audit logs " * 3}</body></html>))
  when "/config"     then context.response.print(%(<html><title>config</title><body>#{"configuration environment secrets datastore flags " * 3}</body></html>))
  else                    context.response.print("<html><body>default landing</body></html>")
  end
end

describe Nokizaru::CLI::Workflow do
  it "starts no module and writes no export once the scan is stopped" do
    wordlist = File.tempname("nok-stop", ".txt")
    File.write(wordlist, "admin\n")
    begin
      requests = Atomic(Int32).new(0)
      handler = ->(context : ::HTTP::Server::Context) do
        requests.add(1)
        scan_handler(context)
      end
      HttpTestServer.with_server(handler) do |base|
        wf = Workflow.new(scan_options(base, wordlist), Nokizaru::Settings.new, STUB)
        plan = silence { wf.plan! }
        wf.stop.stop!

        silence { wf.execute!(plan) }

        requests.get.should eq(0)
        plan.state.modules.headers.should be_nil
        plan.state.modules.directory_enum.should be_nil
      end
    ensure
      File.delete(wordlist) if File.exists?(wordlist)
    end
  end

  it "runs the enabled modules and fills the typed run state" do
    wordlist = File.tempname("nok-wf", ".txt")
    File.write(wordlist, "admin\nconfig\nsecret\n")
    begin
      handler = ->(context : ::HTTP::Server::Context) { scan_handler(context) }
      HttpTestServer.with_server(handler) do |base|
        wf = Workflow.new(scan_options(base, wordlist), Nokizaru::Settings.new, STUB)
        plan = silence { wf.plan! }
        text = present_capture do
          wf.execute!(plan)
          elapsed, export_dir = wf.finalize!(plan)
          elapsed.should be >= 0.0
          export_dir.should be_nil
        end

        plan.state.modules.headers.should_not be_nil
        plan.state.modules.crawler.should_not be_nil
        plan.state.modules.directory_enum.should_not be_nil
        plan.state.modules.sslinfo.should be_nil # not enabled
        plan.state.findings.should be_a(Array(Nokizaru::Finding))

        plan.state.modules.directory_enum.not_nil!.confirmed_found.any?(&.ends_with?("/admin")).should be_true
        artifacts = JSON.parse(plan.state.to_json)["artifacts"]
        crawler = plan.state.modules.crawler.not_nil!
        directory = plan.state.modules.directory_enum.not_nil!
        artifacts["urls"].as_a.map(&.as_s).should eq(crawler.stats.total_urls)
        artifacts["high_signal_urls"].as_a.map(&.as_s).should eq(crawler.high_signal_urls)
        artifacts["paths"].as_a.map(&.as_s).should eq(directory.prioritized_found)
        artifacts["prioritized_paths"].as_a.map(&.as_s).should eq(directory.prioritized_found)

        text.should contain("Headers")
        text.should contain("Crawler")
        text.should contain("Directory Enum")
        text.should contain("Completed in")
      end
    ensure
      File.delete(wordlist) rescue nil
    end
  end

  it "prints the banner and completion line from a full run" do
    handler = ->(context : ::HTTP::Server::Context) { scan_handler(context) }
    HttpTestServer.with_server(handler) do |base|
      opts = Options.new
      opts.target = base
      opts.modules << "headers"
      opts.timeout = 5.0
      wf = Workflow.new(opts, Nokizaru::Settings.new, STUB)

      text = present_capture do
        elapsed, export_dir = wf.run
        elapsed.should be >= 0.0
        export_dir.should be_nil
      end

      text.should contain(Nokizaru::VERSION) # banner row
      text.should contain("Completed in")
    end
  end

  it "raises when no modules are selected" do
    opts = Options.new
    opts.target = "https://example.com"
    wf = Workflow.new(opts, Nokizaru::Settings.new, STUB)
    expect_raises(Workflow::Error, /No Modules/) { wf.plan! }
  end

  it "skips the port scan when the target IP could not be resolved" do
    opts = Options.new
    opts.target = "https://nope.invalid"
    opts.modules << "ps"
    wf = Workflow.new(opts, Nokizaru::Settings.new, ->(_h : String) { nil.as(String?) })

    plan = silence { wf.plan! }
    text = present_capture { wf.execute!(plan) }

    text.should contain("Skipping Port Scan")
    plan.state.modules.portscan.should be_nil
  end

  it "skips subdomain enumeration for an IP target" do
    opts = Options.new
    opts.target = "http://127.0.0.1:9"
    opts.modules << "sub"
    wf = Workflow.new(opts, Nokizaru::Settings.new, STUB)

    plan = silence { wf.plan! }
    text = present_capture { wf.execute!(plan) }

    text.should contain("Not Supported for IP Addresses")
    plan.state.modules.subdomains.should be_nil
  end

  describe "#module_timeout_s" do
    it "applies the per-module budget floors over the base timeout" do
      opts = Options.new
      opts.target = "https://example.com"
      opts.timeout = 5.0
      wf = Workflow.new(opts, Nokizaru::Settings.new, STUB)
      info = Nokizaru::TargetInfo.resolve(opts, resolve_ip: STUB)

      wf.module_timeout_s(info, "headers").should eq(25.0)
      wf.module_timeout_s(info, "dns").should eq(40.0)
      wf.module_timeout_s(info, "sub").should eq(60.0)
      wf.module_timeout_s(info, "wayback").should eq(24.0)
      wf.module_timeout_s(info, "crawl").should eq(0.0)
    end
  end

  describe "#requested_port_count" do
    it "counts a custom spec and ignores the default spec" do
      opts = Options.new
      opts.target = "https://example.com"
      wf = Workflow.new(opts, Nokizaru::Settings.new, STUB)

      wf.requested_port_count(nil).should be_nil
      wf.requested_port_count("top").should be_nil
      wf.requested_port_count("80,443,8000-8001").should eq(4)
    end
  end
end
