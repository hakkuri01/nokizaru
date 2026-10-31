require "file_utils"
require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/cli/headless"

private alias Headless = Nokizaru::CLI::Headless
private alias Workflow = Nokizaru::CLI::Workflow
private alias Options = Nokizaru::CLI::Options

private STUB = ->(_host : String) { "127.0.0.1".as(String?) }

private def options(target : String, modules : Array(String)) : Options
  opts = Options.new
  opts.target = target
  modules.each { |mod| opts.modules << mod }
  opts.timeout = 5.0
  opts
end

# Runs a headless scan and returns {status, stdout, stderr}
private def run_headless(opts : Options, stop : Nokizaru::ScanStop = Nokizaru::ScanStop.new) : {Int32, String, String}
  sink = IO::Memory.new
  log = IO::Memory.new
  status = Headless.new(Workflow.new(opts, Nokizaru::Settings.new, STUB, stop), sink: sink, log: log).run
  {status, sink.to_s, log.to_s}
end

private def page(context : ::HTTP::Server::Context) : Nil
  context.response.content_type = "text/html"
  case context.request.path
  when "/"      then context.response.print(%(<html><body><a href="/admin">a</a></body></html>))
  when "/admin" then context.response.print(%(<html><title>admin</title><body>#{"admin console users roles " * 4}</body></html>))
  else               context.response.print("<html><body>default landing</body></html>")
  end
end

describe Nokizaru::CLI::Headless do
  it "writes only the JSON result to stdout and the module lifecycle to stderr" do
    wordlist = File.tempname("nok-headless", ".txt")
    File.write(wordlist, "admin\nconfig\n")
    begin
      HttpTestServer.with_server(->(context : ::HTTP::Server::Context) { page(context) }) do |base|
        opts = options(base, %w[headers crawl dir])
        opts.wordlist = wordlist
        original = Nokizaru::UI.output
        status, stdout, stderr = run_headless(opts)

        status.should eq(0)
        modules = JSON.parse(stdout)["modules"]
        modules["headers"].as_h?.should_not be_nil
        modules["directory_enum"].as_h?.should_not be_nil
        stdout.should_not contain("\e")
        stderr.lines.should contain("[headers] running")
        stderr.lines.should contain("[dir] done")
        stderr.should contain("completed in")
        stderr.should_not contain("\e")
        Nokizaru::UI.output.should be(original)
      end
    ensure
      File.delete(wordlist) if File.exists?(wordlist)
    end
  end

  it "writes the --export files instead of stdout and names the directory on stderr" do
    dir = File.tempname("nok-headless-export")
    begin
      HttpTestServer.with_server(->(context : ::HTTP::Server::Context) { page(context) }) do |base|
        opts = options(base, %w[headers])
        opts.export = true
        opts.formats = "json"
        opts.export_dir = dir
        opts.export_basename = "run"
        status, stdout, stderr = run_headless(opts)

        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("exported to #{dir}")
        JSON.parse(File.read(File.join(dir, "run.json")))["modules"]["headers"].as_h?.should_not be_nil
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports a fatal plan error on stderr with status 1 and a clean stdout" do
    status, stdout, stderr = run_headless(options("https://example.com", [] of String))
    status.should eq(1)
    stdout.should be_empty
    stderr.should eq("error: No Modules Specified! Use --full or a module flag\n")
  end

  # Modules record their own errors in their results, so an unreachable target
  # is a completed scan whose JSON says so, not a failed run.
  it "exits 0 with the module's own error in the JSON when the target is down" do
    status, stdout, stderr = run_headless(options("http://127.0.0.1:9", %w[headers]))
    status.should eq(0)
    JSON.parse(stdout)["modules"]["headers"]["error"].as_s.should contain("Connection refused")
    stderr.lines.should contain("[headers] done")
  end

  it "gives the skip reason on stderr and exits 0 when modules are only skipped" do
    status, stdout, stderr = run_headless(options("http://127.0.0.1:9", %w[sub]))
    status.should eq(0)
    JSON.parse(stdout)["modules"]["subdomains"]?.should be_nil
    stderr.lines.should contain("[sub] skipped: Skipping Sub-Domain Enumeration : Not Supported for IP Addresses")
  end

  # The fixture holds the first response until the signal handler has raised the
  # stop flag, so the runner deterministically starts nothing after headers.
  it "keeps what finished and exits 130 when interrupted mid-scan" do
    stop = Nokizaru::ScanStop.new
    signalled = Atomic(Int32).new(0)
    handler = ->(context : ::HTTP::Server::Context) do
      if signalled.swap(1) == 0
        Process.signal(Signal::INT, Process.pid)
        400.times { break if stop.stopped?; sleep 5.milliseconds }
      end
      page(context)
    end
    HttpTestServer.with_server(handler) do |base|
      status, stdout, stderr = run_headless(options(base, %w[headers crawl dir]), stop)

      status.should eq(130)
      modules = JSON.parse(stdout)["modules"]
      modules["headers"].as_h?.should_not be_nil
      modules["crawler"]?.try(&.as_h?).should be_nil
      modules["directory_enum"]?.try(&.as_h?).should be_nil
      stderr.should contain("interrupted: finishing the module in flight")
      stderr.lines.should_not contain("[crawl] running")
    end
  end
end
