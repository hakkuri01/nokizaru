require "../spec_helper"
require "../../src/nokizaru/tui/dashboard"

private alias Dashboard = Nokizaru::Tui::Dashboard
private alias Profile = Nokizaru::Tui::Profile
private alias Progress = Nokizaru::Tui::Progress
private alias M = Nokizaru::Tui::Messages

private def dash(cols = 100, rows = 32) : Dashboard
  profile = Profile.new(target: "https://example.com", ip: "93.184.216.34",
    modules: "headers sslinfo whois dns", switches: "none",
    modules_enabled: ["headers", "sslinfo", "whois", "dns"])
  Dashboard.new(profile, 0.0, cols, rows)
end

private def snapshot(current : String, phases : Hash(String, Progress::Phase)) : Progress::Snapshot
  mods = {} of String => Progress::ModuleState
  phases.each { |key, phase| mods[key] = Progress::ModuleState.new(phase, key) }
  Progress::Snapshot.new(["headers", "sslinfo", "whois", "dns"], current, mods)
end

private def strip(frame)
  Nokizaru::TerminalText.strip_sgr(frame.join("\n"))
end

describe Nokizaru::Tui::Dashboard do
  it "opens one tab per enabled module plus a Summary tab" do
    dash.tabs.map(&.label).should eq(["Headers", "SSL", "Whois", "DNS", "Summary"])
  end

  it "streams results on a vertical scaffold without a module header bar" do
    d = dash
    d.update(M::Tick.new(1.0,
      snapshot("dns", {"headers" => Progress::Phase::Done, "sslinfo" => Progress::Phase::Done,
                       "whois" => Progress::Phase::Done, "dns" => Progress::Phase::Running}),
      {} of String => String))
    d.update(M::Lines.new([M::FeedLine.new("dns", "A 93.184.216.34")]))
    frame = d.view
    text = strip(frame)
    text.should contain("◈ DNS")
    text.should contain("93.184.216.34")
    text.should contain("│")
    frame.any? { |row| row.includes?("────") && row.includes?("DNS Enumeration") }.should be_false
    frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 100 }
  end

  it "follows the running module, then stays on command with tab and number keys" do
    d = dash
    d.update(M::Tick.new(1.0, snapshot("whois", {"whois" => Progress::Phase::Running}), {} of String => String))
    d.focus.should eq(2) # followed to Whois
    d.update(M::Key.new("tab"))
    d.focus.should eq(3)
    d.update(M::Key.new("shift+tab"))
    d.focus.should eq(2)
    d.update(M::Key.new("1"))
    d.focus.should eq(0)
  end

  it "reports completion with the elapsed time and export directory" do
    d = dash
    d.update(M::ScanDone.new(12.34, "/tmp/exports", 0))
    d.running?.should be_false
    status = Nokizaru::TerminalText.strip_sgr(d.status_text(100))
    status.should contain("Completed in 12.34s")
    status.should contain("Exported /tmp/exports")
  end

  it "reports a failure reason" do
    d = dash
    d.update(M::ScanFailed.new("Unexpected error: boom"))
    d.running?.should be_false
    Nokizaru::TerminalText.strip_sgr(d.status_text(100)).should contain("boom")
  end

  it "renders a compact frame below the full minimum and a notice when too small" do
    compact = dash(60, 20)
    compact.view.size.should eq(20)
    strip(compact.view).should contain("NOKIZARU")

    strip(dash(40, 10).view).should contain("Terminal too small")
  end

  it "tracks dirtiness and resizes to a new terminal size" do
    d = dash
    d.dirty?.should be_true
    d.clean!
    d.dirty?.should be_false
    d.update(M::Resize.new(120, 40))
    d.dirty?.should be_true
    d.view.size.should eq(40)
  end
end
