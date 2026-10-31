require "./spec_helper"
require "../src/nokizaru/progress_rail"
require "../src/nokizaru/tui/status_line"

private alias ProgressRail = Nokizaru::ProgressRail

describe Nokizaru::ProgressRail do
  it "starts every enabled module pending with the first current" do
    snap = ProgressRail.new(["headers", "dns", "ps"]).snapshot
    snap.enabled_modules.should eq(["headers", "dns", "ps"])
    snap.current_module.should eq("headers")
    snap.modules["headers"].phase.pending?.should be_true
  end

  it "tracks phase transitions and the current module" do
    rail = ProgressRail.new(["dns", "ps"])
    rail.module_started("dns", "DNS Enumeration")
    rail.current_module.should eq("dns")
    rail.snapshot.modules["dns"].phase.running?.should be_true
    rail.snapshot.modules["dns"].label.should eq("DNS Enumeration")
    rail.module_finished("dns")
    rail.snapshot.modules["dns"].phase.done?.should be_true
    rail.module_failed("ps", "")
    rail.snapshot.modules["ps"].phase.failed?.should be_true
    rail.module_skipped("ps", "Ports", "")
    rail.snapshot.modules["ps"].phase.skipped?.should be_true
  end

  it "publishes module-formatted detail through an injected reporter" do
    rail = ProgressRail.new(["ps"])
    rail.reporter("ps").report(detail: "45/1000 open 3")
    rail.snapshot.modules["ps"].detail.should eq("45/1000 open 3")
    rail.current_module.should eq("ps")
    line = Nokizaru::TerminalText.strip_sgr(Nokizaru::Tui::StatusLine.render(rail.snapshot, 0))
    line.should contain("45/1000 open 3")
  end

  it "has a no-op null reporter" do
    Nokizaru::ProgressReporter::NULL.report(detail: "ignored").should be_nil
  end

  it "tells a listener each lifecycle event with its failure or skip reason" do
    events = [] of String
    listener = ->(key : String, phase : Nokizaru::Tui::Progress::Phase, reason : String) { events << "#{key} #{phase} #{reason}".strip; nil }
    rail = ProgressRail.new(["dns", "ps", "sub"], listener)
    rail.module_started("dns", "DNS Enumeration")
    rail.reporter("dns").report(detail: "progress is not a lifecycle event")
    rail.module_finished("dns")
    rail.module_failed("ps", "ModuleTimeout: module exceeded 90.0s")
    rail.module_skipped("sub", "Sub-Domain Enumeration", "Not Supported for IP Addresses")
    events.should eq(["dns Running", "dns Done", "ps Failed ModuleTimeout: module exceeded 90.0s", "sub Skipped Not Supported for IP Addresses"])
  end

  it "leaves the current module alone when an abandoned module reports late" do
    rail = ProgressRail.new(["ps", "wayback"])
    rail.module_started("ps", "Port Scan")
    rail.module_failed("ps", "")
    rail.module_started("wayback", "Wayback")
    rail.reporter("ps").report(detail: "late 900/1000")
    rail.current_module.should eq("wayback")
    rail.snapshot.modules["ps"].detail.should eq("late 900/1000")
  end
end
