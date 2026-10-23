require "../spec_helper"
require "../../src/nokizaru/tui/help_view"

private alias HelpView = Nokizaru::Tui::HelpView

describe Nokizaru::Tui::HelpView do
  describe ".frame" do
    it "renders the grouped flag and key reference inside the HUD" do
      frame = HelpView.frame(100, 40, 0)
      frame.size.should eq(40)
      text = frame.join("\n")
      text.should contain("Flags & Keys")
      text.should contain("MODULES")
      text.should contain("--full")
      text.should contain("j / k")
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 100 }
    end

    it "shows the too-small notice below the compact minimum" do
      HelpView.frame(40, 10, 0).join("\n").should contain("Terminal too small")
    end

    it "shows a scroll indicator when the content overflows the pane" do
      HelpView.frame(100, 24, 3).join("\n").should contain("/")
    end
  end

  describe ".max_offset" do
    it "is positive when the content overflows and zero when it fits" do
      HelpView.max_offset(100, 24).should be > 0
      HelpView.max_offset(100, 200).should eq(0)
    end
  end
end
