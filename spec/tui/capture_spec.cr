require "../spec_helper"
require "../../src/nokizaru/tui/capture"

private alias Capture = Nokizaru::Tui::Capture

describe Nokizaru::Tui::Capture do
  it "emits each complete line and holds the partial remainder" do
    lines = [] of String
    cap = Capture.new(->(line : String) { lines << line; nil })
    cap.print("hello\nwor")
    lines.should eq(["hello"])
    cap.print("ld\n")
    lines.should eq(["hello", "world"])
  end

  it "keeps the open color on each line of a multi-line colored write" do
    lines = [] of String
    cap = Capture.new(->(line : String) { lines << line; nil })
    cap.print("\e[31mred1\nred2\e[0m\n")
    lines.should eq(["\e[31mred1", "\e[31mred2\e[0m"])
  end

  it "releases an endless line at the cap instead of growing without bound" do
    lines = [] of String
    cap = Capture.new(->(line : String) { lines << line; nil })
    cap.print("x" * (Capture::MAX_PENDING_BYTES + 1))
    lines.size.should eq(1)
    lines[0].size.should eq(Capture::MAX_PENDING_BYTES + 1)
  end
end
