require "../spec_helper"
require "../../src/nokizaru/tui/scene"

private alias Scene = Nokizaru::Tui::Scene

private BANNER = ["BANNER-ART-LINE-1", "banner art line 2"]

describe Nokizaru::Tui::Scene do
  describe ".base" do
    it "settles to the identity, banner, and STANDBY, filling the terminal" do
      frame = Scene.base(BANNER, 100, 32)
      frame.size.should eq(32)
      text = Nokizaru::TerminalText.strip_sgr(frame.join("\n"))
      text.should contain("NOKIZARU // v")
      text.should contain("STANDBY")
      text.should contain("BANNER-ART-LINE-1")
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 100 }
    end

    it "centers the banner without the HUD below the full minimum" do
      frame = Scene.base(BANNER, 40, 10)
      frame.size.should eq(10)
      frame.join("\n").should contain("BANNER-ART-LINE-1")
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 40 }
    end
  end

  describe ".frame" do
    it "settles to the base once past the hold" do
      Scene.frame(BANNER, 100, 32, 2.0, 240).should eq(Scene.base(BANNER, 100, 32))
    end

    it "glitches during the reveal and is reproducible for a seed" do
      revealing = Scene.frame(BANNER, 100, 32, 0.3, 36)
      revealing.should_not eq(Scene.base(BANNER, 100, 32))
      revealing.should eq(Scene.frame(BANNER, 100, 32, 0.3, 36))
      revealing.each { |row| Nokizaru::TerminalText.width(row).should be <= 100 }
    end

    it "uses no truecolor gradient" do
      Scene.frame(BANNER, 100, 32, 0.5, 60).join.should_not contain("\e[38;2;")
    end
  end

  describe ".animating?" do
    it "animates until the hold, then stops" do
      Scene.animating?(0.5).should be_true
      Scene.animating?(2.0).should be_false
    end
  end
end
