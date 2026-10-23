require "../spec_helper"
require "../../src/nokizaru/tui/view"

private alias View = Nokizaru::Tui::View
private alias Layout = Nokizaru::Tui::Layout

describe Nokizaru::Tui::View do
  describe ".compose" do
    it "places the top cluster, framed middle rows, and the bottom cluster" do
      geo = Layout.measure(80, 24, 0)
      status_row = geo.status_row.not_nil!
      frame = View.compose(geo, ["TOP0", "TOP1"], {geo.pane_top => "mid"}, ["BOT0", "BOT1", "BOT2"])
      frame.size.should eq(24)
      frame[0].should eq("TOP0")
      frame[1].should eq("TOP1")
      frame[status_row].should eq("BOT0")
      frame[geo.pane_top].should contain("mid")
    end
  end

  describe ".tiny" do
    it "centers the too-small notice within the terminal" do
      frame = View.tiny(40, 10)
      frame.size.should eq(10)
      frame.any?(&.includes?("Terminal too small")).should be_true
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 40 }
    end

    it "returns an empty frame when there are no rows" do
      View.tiny(40, 0).should be_empty
    end
  end
end
