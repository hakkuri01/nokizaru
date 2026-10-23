require "../spec_helper"
require "../../src/nokizaru/cli/runtime"

private alias Runtime = Nokizaru::CLI::Runtime
private alias TargetInfo = Nokizaru::TargetInfo
private alias Options = Nokizaru::CLI::Options

private STUB = ->(_host : String) { "93.184.216.34".as(String?) }

private def options(target : String? = "https://www.example.com") : Options
  opts = Options.new
  opts.target = target
  opts
end

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

describe Nokizaru::CLI::Runtime do
  describe ".banner" do
    it "prints the author, version, and repo rows" do
      text = present_capture { Runtime.banner }
      text.should contain("AUTHOR")
      text.should contain("hakkuri")
      text.should contain("VERSION")
      text.should contain(Nokizaru::VERSION)
      text.should contain("GIT")
      text.should contain("https://github.com/hakkuri01")
    end
  end

  describe ".present_target" do
    it "renders the target and resolved IP, no notice" do
      info = TargetInfo.resolve(options, resolve_ip: STUB)
      text = present_capture { Runtime.present_target(info) }
      text.should contain("Target")
      text.should contain("https://www.example.com")
      text.should contain("IP Address")
      text.should contain("93.184.216.34")
      text.should_not contain("Target Notice")
    end

    it "shows an unresolved host with its resolution error" do
      info = TargetInfo.resolve(options("https://nope.invalid"), resolve_ip: ->(_h : String) { nil.as(String?) })
      text = present_capture { Runtime.present_target(info) }
      text.should contain("unresolved (")
    end

    it "prints the unusual scheme/port notice first" do
      info = TargetInfo.resolve(options("http://example.com:443"), resolve_ip: STUB)
      text = present_capture { Runtime.present_target(info) }
      text.should contain("Target Notice")
      text.should contain("Using http with port 443")
    end
  end

  describe ".initial_run_state" do
    it "builds meta from the resolved target with empty results" do
      info = TargetInfo.resolve(options, resolve_ip: STUB)
      started = Time.utc(2026, 1, 1, 12, 0, 0)
      run = Runtime.initial_run_state(info, started)

      run.meta.version.should eq(Nokizaru::VERSION)
      run.meta.target.should eq("https://www.example.com")
      run.meta.hostname.should eq("www.example.com")
      run.meta.ip.should eq("93.184.216.34")
      run.meta.started_at.should eq("2026-01-01T12:00:00Z")
      run.meta.ended_at.should be_nil
      run.meta.elapsed_s.should be_nil
      run.artifacts.empty?.should be_true
      run.findings.empty?.should be_true
      JSON.parse(run.modules.to_json).as_h.empty?.should be_true
    end

    it "keeps hostname and ip as null keys when unresolved" do
      info = TargetInfo.resolve(options("https://nope.invalid"), resolve_ip: ->(_h : String) { nil.as(String?) })
      run = Runtime.initial_run_state(info, Time.utc(2026, 1, 1))
      run.meta.ip.should be_nil
      meta = JSON.parse(run.meta.to_json).as_h
      meta.has_key?("ip").should be_true
      meta["ip"].raw.should be_nil
    end
  end

  describe ".finalize_timing" do
    it "stamps ended_at and elapsed_s and returns the elapsed seconds" do
      info = TargetInfo.resolve(options, resolve_ip: STUB)
      started = Time.utc(2026, 1, 1, 12, 0, 0)
      run = Runtime.initial_run_state(info, started)

      elapsed = Runtime.finalize_timing(run, started, started + 3.5.seconds)

      elapsed.should eq(3.5)
      run.meta.elapsed_s.should eq(3.5)
      run.meta.ended_at.should eq("2026-01-01T12:00:03Z")
    end
  end
end
