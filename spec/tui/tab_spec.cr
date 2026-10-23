require "../spec_helper"
require "../../src/nokizaru/tui/tab"

private alias Tab = Nokizaru::Tui::Tab

describe Nokizaru::Tui::Tab do
  it "wraps appended lines to the pane width" do
    tab = Tab.new("dns", "DNS")
    tab.append("x" * 25)
    tab.rows(10).size.should eq(3)
  end

  it "tails, scrolls within bounds, and jumps to top" do
    tab = Tab.new("dir", "Dir")
    100.times { |i| tab.append("line #{i}") }
    width = 40
    height = 10
    total = tab.rows(width).size
    tab.top(width, height).should eq(total - height)
    tab.scroll(-5, width, height)
    tab.top(width, height).should eq(total - height - 5)
    tab.scroll_to_top
    tab.top(width, height).should eq(0)
    tab.follow_tail
    tab.top(width, height).should eq(total - height)
  end

  it "drops the oldest lines past the cap and counts them" do
    tab = Tab.new("dir", "Dir")
    (Tab::MAX_LINES + 5).times { |i| tab.append("l#{i}") }
    tab.lines.size.should eq(Tab::MAX_LINES)
    tab.dropped.should eq(5)
  end
end
