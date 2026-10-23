require "../spec_helper"
require "../../src/nokizaru/tui/hud"

private alias Hud = Nokizaru::Tui::Hud
private alias Layout = Nokizaru::Tui::Layout

private def strip(row)
  Nokizaru::TerminalText.strip_sgr(row)
end

private def sample_profile(notice = nil)
  Nokizaru::Tui::Profile.new(
    target: "https://example.com", ip: "93.184.216.34", modules: "full",
    switches: "none", modules_enabled: ["headers", "dns"], notice: notice,
  )
end

private def sample_cheats
  [Hud::Cheat.new("enter", "run"), Hud::Cheat.new("q", "quit")]
end

describe Nokizaru::Tui::Hud do
  describe ".top" do
    it "renders the bracketed identity, the outer rail, and one branch per field" do
      geo = Layout.measure(120, 32, 4, footers: 2)
      rows = Hud.top(sample_profile, geo, sample_cheats)
      rows.size.should eq(6) # identity rail x2 + 4 branches
      strip(rows[0]).should start_with("┌")
      strip(rows[1]).should contain("┣━┤ NOKIZARU // v")
      strip(rows[1]).should contain("├━")
      strip(rows[2]).should contain("├─◈ Target.......⟦ https://example.com ⟧")
      strip(rows[3]).should contain("├─◈ IP Address...⟦ 93.184.216.34 ⟧")
      strip(rows[4]).should contain("├─◈ Modules......⟦ full ⟧")
    end

    it "adds a Notice branch only when the profile carries one" do
      geo = Layout.measure(120, 32, 5, footers: 2)
      rows = Hud.top(sample_profile("Using http with port 8080"), geo, sample_cheats)
      rows.size.should eq(7)
      strip(rows[6]).should contain("├─◈ Notice")
      strip(rows[6]).should contain("Using http with port 8080")
    end
  end

  describe ".bottom" do
    it "hangs each readout off a branch node and ends on the mirrored corner" do
      geo = Layout.measure(120, 32, 4, footers: 2)
      rows = Hud.bottom(["NORMAL", "READY"], sample_cheats, geo)
      strip(rows[0]).rstrip.should end_with("◈─┨")
      strip(rows[0]).should contain("NORMAL")
      strip(rows[1]).rstrip.should end_with("◈─┨")
      strip(rows[-1]).should end_with("┘")
      strip(rows[-1]).should contain("▱▰▰")
    end

    it "renders the cheatsheet with bracketed middle-dot separators" do
      geo = Layout.measure(120, 32, 4, footers: 2)
      row = strip(Hud.bottom(["NORMAL"], sample_cheats, geo)[-2])
      row.should contain("┤ ")
      row.should contain(" · ")
      row.should contain("enter run")
    end
  end

  # The owner-critical rail geometry (a port of Jekyll // Hyde's header_cap):
  # both outer and inner top<->bottom pairs mirror at cols-1, and the inner-vs-outer
  # offset (the diagonal) is identical top and bottom at every width.
  describe "rail cap symmetry" do
    it "keeps both rail pairs mirrored and the diagonal symmetric across widths" do
      [100, 120, 160, 240].each do |cols|
        geo = Layout.measure(cols, 32, 4, footers: 2)
        top = Hud.top(sample_profile, geo, sample_cheats)
        bottom = Hud.bottom(["NORMAL", "READY"], sample_cheats, geo)

        outer_top = strip(top[0]).index!("▰▰▱") + 2
        inner_top = strip(top[1]).index!("▰▰▱") + 2
        inner_bottom = strip(bottom[-2]).index!("▱▰▰")
        outer_bottom = strip(bottom[-1]).index!("▱▰▰")

        (outer_top + outer_bottom).should eq(cols - 1)
        (inner_top + inner_bottom).should eq(cols - 1)
        (inner_top - outer_top).should eq(outer_bottom - inner_bottom)
      end
    end
  end

  describe ".compact_top / .compact_status" do
    it "shows the identity and target on one row, right-aligns the status" do
      top = strip(Hud.compact_top(sample_profile, 60))
      top.should contain("◈ NOKIZARU // v")
      top.should contain("example.com")
      Nokizaru::TerminalText.width(top).should be <= 60

      status = Hud.compact_status("scanning", 60)
      strip(status).should contain("scanning")
      Nokizaru::TerminalText.width(status).should be <= 60
    end
  end

  describe ".left_trunk / .right_trunk" do
    it "draws a solid then faint trunk within its length, blank outside it" do
      geo = Layout.measure(100, 32, 4, footers: 2)
      strip(Hud.left_trunk(geo, 6)).should eq("│")   # offset 0, solid
      strip(Hud.left_trunk(geo, 13)).should eq("╎")  # offset 7, faint
      Hud.left_trunk(geo, 5).should eq(" ")          # offset -1, blank
      strip(Hud.right_trunk(geo, 27)).should eq("│") # offset 0, solid
      Hud.right_trunk(geo, 28).should eq("")         # offset -1, blank
    end
  end
end
