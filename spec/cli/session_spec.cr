require "../spec_helper"
require "../../src/nokizaru/cli/session"

private alias Session = Nokizaru::CLI::Session
private alias Workflow = Nokizaru::CLI::Workflow
private alias Options = Nokizaru::CLI::Options

private STUB = ->(_host : String) { "127.0.0.1".as(String?) }

private def silence(&block : -> T) : T forall T
  Nokizaru::UI.output = IO::Memory.new
  block.call
ensure
  Nokizaru::UI.output = STDOUT
end

describe Nokizaru::CLI::Session do
  it "implements the Program controller contract for a power-user launch" do
    opts = Options.new
    opts.target = "http://127.0.0.1:9" # IP literal, so plan! needs no DNS or network
    opts.modules << "headers"
    opts.modules << "dns"
    workflow = Workflow.new(opts, Nokizaru::Settings.new, STUB)
    plan = silence { workflow.plan! }

    session = Session.new(opts, Nokizaru::Settings.new, STUB)
    session.scanning?.should be_false
    session.feed.should be_nil
    session.wake_channel.should be_a(Channel(Nil))

    session.launch!(workflow, plan)
    snapshot, statuses = session.observe
    snapshot.should_not be_nil
    snapshot.try(&.enabled_modules).should eq(["headers", "dns"]) # MODULE_ORDER-filtered
    statuses.empty?.should be_true                                # no module results yet
  end

  it "returns an empty observation before a scan is planned" do
    session = Session.new(Options.new, Nokizaru::Settings.new, STUB)
    snapshot, statuses = session.observe
    snapshot.should be_nil
    statuses.empty?.should be_true
  end
end
