require "../spec_helper"
require "../../src/nokizaru/tui/status_line"

private alias SL = Nokizaru::Tui::StatusLine
private alias Progress = Nokizaru::Tui::Progress

private def running_snapshot : Progress::Snapshot
  Progress::Snapshot.new(["headers", "dns"], "dns",
    {"headers" => Progress::ModuleState.new(Progress::Phase::Done, "Headers"),
     "dns"     => Progress::ModuleState.new(Progress::Phase::Running, "DNS Enumeration")})
end

describe Nokizaru::Tui::StatusLine do
  it "renders the pulse rail and the current module summary" do
    line = Nokizaru::TerminalText.strip_sgr(SL.render(running_snapshot, 0))
    line.should contain("■")
    line.should contain("Module 2/2")
    line.should contain("DNS Enumeration")
    line.should contain("running")
  end

  it "advances the pulse with the frame index" do
    SL.render(running_snapshot, 0).should_not eq(SL.render(running_snapshot, 1))
  end

  it "fits a width budget" do
    line = SL.render(running_snapshot, 0, 20)
    Nokizaru::TerminalText.width(line).should be <= 20
  end
end
