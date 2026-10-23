require "../spec_helper"
require "../../src/nokizaru/tui/screen"

private RESET    = "\e[0m"
private SYNC_ON  = "\e[?2026h"
private SYNC_OFF = "\e[?2026l"

describe Nokizaru::Tui::Screen do
  describe "#render" do
    it "writes every row cursor-addressed inside one synchronized update" do
      io = IO::Memory.new
      screen = Nokizaru::Tui::Screen.new(io)
      screen.render(["hi"])
      io.to_s.should eq("#{SYNC_ON}\e[1;1H\e[2Khi#{RESET}#{SYNC_OFF}")
    end

    it "emits nothing when the frame is unchanged" do
      io = IO::Memory.new
      screen = Nokizaru::Tui::Screen.new(io)
      screen.render(["a", "b"])
      before = io.to_s.size
      screen.render(["a", "b"])
      io.to_s.size.should eq(before)
    end

    it "rewrites only the rows that differ" do
      io = IO::Memory.new
      screen = Nokizaru::Tui::Screen.new(io)
      screen.render(["a", "b"])
      before = io.to_s.size
      screen.render(["a", "c"])
      io.to_s[before..].should eq("#{SYNC_ON}\e[2;1H\e[2Kc#{RESET}#{SYNC_OFF}")
    end

    it "clears rows the new frame no longer fills" do
      io = IO::Memory.new
      screen = Nokizaru::Tui::Screen.new(io)
      screen.render(["a", "b"])
      before = io.to_s.size
      screen.render(["a"])
      io.to_s[before..].should eq("#{SYNC_ON}\e[2;1H\e[2K#{SYNC_OFF}")
    end
  end

  describe "#invalidate" do
    it "forces the next render to redraw every row" do
      io = IO::Memory.new
      screen = Nokizaru::Tui::Screen.new(io)
      screen.render(["a"])
      before = io.to_s.size
      screen.invalidate
      screen.render(["a"])
      io.to_s[before..].should eq("#{SYNC_ON}\e[1;1H\e[2Ka#{RESET}#{SYNC_OFF}")
    end
  end
end
