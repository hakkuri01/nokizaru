require "./spec_helper"
require "../src/nokizaru/terminal_text"

alias T = Nokizaru::TerminalText

describe Nokizaru::TerminalText do
  it "keeps SGR color while sanitizing" do
    line = "\e[33m⟦!⟧\e[0m Server...⟦ \e[36mnginx\e[0m ⟧"
    T.sanitize(line).should eq(line)
  end

  it "drops non-SGR escape classes" do
    hostile = {
      "csi cursor move"        => "a\e[2Ab",
      "csi erase"              => "a\e[2Jb",
      "osc clipboard with bel" => "a\e]52;c;ZXZpbA==\ab",
      "osc title with st"      => "a\e]0;owned\e\\b",
      "dcs"                    => "a\eP1$r0m\e\\b",
      "apc"                    => "a\e_payload\e\\b",
      "two byte escape"        => "a\ecb",
      "charset escape"         => "a\e(0b",
      "c0 bell and backspace"  => "a\a\bb",
      "carriage return"        => "a\rb",
      "del"                    => "a\x7fb",
      "c1 csi"                 => "a\u{9b}2Jb",
      "c1 osc"                 => "a\u{9d}0;owned\u{9c}b",
      "bidi override"          => "a\u{202e}b",
    }
    hostile.each do |name, text|
      result = T.sanitize(text)
      fail "#{name}: expected \"ab\", got #{result.inspect}" unless result == "ab"
    end
  end

  it "drops an unterminated OSC and a trailing escape" do
    T.sanitize("a\e]52;c;ZXZpbA").should eq("a")
    T.sanitize("a\e").should eq("a")
  end

  it "expands tabs and scrubs invalid UTF-8" do
    T.sanitize("a\tb").should eq("a    b")
    invalid = String.new(Bytes[0x61_u8, 0xff_u8, 0x62_u8])
    T.sanitize(invalid).should eq("a\u{fffd}b")
  end

  it "counts cells for width" do
    T.width("\e[31mhello\e[0m").should eq(5)
    T.width("東京").should eq(4)
    T.width("⟦■⟧ ◈").should eq(5)
    T.width("🚀").should eq(2)
    T.width("e\u{301}").should eq(1)
  end

  it "wrap hard-breaks and reopens color" do
    rows = T.wrap("\e[36mabcdefgh\e[0m", 3)
    rows.should eq(["\e[36mabc\e[0m", "\e[36mdef\e[0m", "\e[36mgh\e[0m"])
    rows.all? { |row| T.width(row) <= 3 }.should be_true
  end

  it "wrap never splits a wide character" do
    T.wrap("a東京", 2).should eq(["a", "東", "京"])
  end

  it "wrap returns short lines untouched" do
    T.wrap("short", 10).should eq(["short"])
    T.wrap("", 10).should eq([""])
  end

  it "truncate marks the cut" do
    T.truncate("abcdefgh", 5).should eq("abcd#{T::RESET}…")
    T.truncate("abc", 5).should eq("abc")
    T.truncate("abcdefgh", 1).should eq("…")
  end

  it "active_sgr tracks the open color" do
    T.active_sgr("\e[31mbanner line").should eq("\e[31m")
    T.active_sgr("\e[31mred\e[0m plain").should eq("")
  end
end
