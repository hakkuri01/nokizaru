require "../spec_helper"
require "../../src/nokizaru/tui/progress"

private alias Progress = Nokizaru::Tui::Progress

describe Nokizaru::Tui::Progress do
  it "carries module states in a snapshot" do
    state = Progress::ModuleState.new(Progress::Phase::Running, "DNS")
    snap = Progress::Snapshot.new(["dns"], "dns", {"dns" => state})
    snap.enabled_modules.should eq(["dns"])
    snap.current_module.should eq("dns")
    snap.modules["dns"].phase.running?.should be_true
    snap.modules["dns"].label.should eq("DNS")
    state.stage.should eq("")
    state.detail.should eq("")
  end

  it "compares snapshots by value" do
    build = -> {
      Progress::Snapshot.new(["dns"], "dns",
        {"dns" => Progress::ModuleState.new(Progress::Phase::Done, "DNS")})
    }
    build.call.should eq(build.call)
  end
end
