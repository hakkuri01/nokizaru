require "../spec_helper"
require "../../src/nokizaru/tui/layout"

private alias Layout = Nokizaru::Tui::Layout

describe Nokizaru::Tui::Layout do
  describe ".measure" do
    it "lays out the full HUD at or above the full minimum" do
      geo = Layout.measure(100, 32, 4, footers: 2)
      geo.mode.should eq(Layout::Mode::Full)
      geo.cols.should eq(100)
      geo.rows.should eq(32)
      geo.branches.should eq(4)
      geo.tab_row.should eq(7)
      geo.rule_row.should eq(8)
      geo.pane_top.should eq(9)
      geo.pane_height.should eq(19)
      geo.pane_left.should eq(3)
      geo.pane_width.should eq(94)
      geo.status_row.should eq(28)
    end

    it "falls back to a compact layout below the full minimum" do
      geo = Layout.measure(60, 20, 0)
      geo.mode.should eq(Layout::Mode::Compact)
      geo.branches.should eq(0)
      geo.tab_row.should eq(1)
      geo.rule_row.should eq(2)
      geo.pane_top.should eq(3)
      geo.pane_height.should eq(16)
      geo.pane_left.should eq(1)
      geo.pane_width.should eq(58)
      geo.status_row.should eq(19)
    end

    it "reports too small below the compact minimum" do
      geo = Layout.measure(40, 10, 0)
      geo.mode.should eq(Layout::Mode::Tiny)
      geo.tab_row.should be_nil
      geo.rule_row.should be_nil
      geo.status_row.should be_nil
      geo.pane_width.should eq(0)
      geo.pane_height.should eq(0)
    end
  end

  describe ".main_rail / .trunk_length" do
    it "computes the shared rail length and trunk length by integer division" do
      Layout.main_rail(100).should eq(55)
      Layout.main_rail(240).should eq(132)
      Layout.trunk_length(32).should eq(12)
      Layout.trunk_length(60).should eq(24)
    end
  end
end
