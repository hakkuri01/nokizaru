require "./spec_helper"
require "../src/nokizaru/ui"

# Runs a block with UI output captured into an IO::Memory, restoring the sink
# after, so a spec can assert on what a module would have printed.
private def ui_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield io
ensure
  Nokizaru::UI.output = STDOUT
end

describe Nokizaru::UI do
  it "writes to the injected sink, not the process stream" do
    ui_capture do |io|
      Nokizaru::UI.line(:info, "hello")
      io.to_s.should contain("hello")
    end
  end

  it "module_header uses a red title with the plus marker" do
    ui_capture do |io|
      Nokizaru::UI.module_header("Headers")
      out = io.to_s
      out.should contain("#{Nokizaru::UI::R}Headers#{Nokizaru::UI::W}")
      out.should contain(Nokizaru::UI.prefix(:plus))
      out.should_not contain("#{Nokizaru::UI::C}Headers")
    end
  end

  it "skips the module header bar in TUI mode" do
    ui_capture do |io|
      Nokizaru::UI.tui_mode = true
      Nokizaru::UI.module_header("Headers")
      io.to_s.should be_empty
    ensure
      Nokizaru::UI.tui_mode = false
    end
  end

  it "renders a section title in cyan" do
    ui_capture do |io|
      Nokizaru::UI.section("Target Profile")
      io.to_s.should contain("#{Nokizaru::UI::C}Target Profile#{Nokizaru::UI::W}")
    end
  end

  it "formats a dotted-leader row with a bracketed value" do
    row = Nokizaru::UI.formatted_row(:info, "Server", "nginx")
    row.should contain("Server")
    row.should contain("...")
    row.should contain("⟦ #{Nokizaru::UI::C}nginx")
  end

  it "shows a dash for a missing value and sanitizes target text" do
    Nokizaru::UI.normalized_value_text(nil).should eq("-")
    Nokizaru::UI.normalized_value_text("  ").should eq("-")
    Nokizaru::UI.safe("a\e[2Jb").should eq("ab")
  end

  it "prints a row and a blank line through the sink" do
    ui_capture do |io|
      Nokizaru::UI.row(:info, "Status", "200")
      Nokizaru::UI.blank_line
      io.to_s.should contain("Status")
    end
  end

  it "aligns a set of rows on the widest label" do
    ui_capture do |io|
      Nokizaru::UI.rows(:info, [{"a", "1".as(String?)}, {"longer", "2".as(String?)}])
      out = io.to_s
      out.should contain("a")
      out.should contain("longer")
    end
  end

  it "draws a tree with branch glyphs and a last-row corner" do
    ui_capture do |io|
      Nokizaru::UI.tree_header("Records")
      Nokizaru::UI.tree_rows([{"A", "1.2.3.4".as(String?)}, {"MX", "mail".as(String?)}])
      out = io.to_s
      out.should contain("Records")
      out.should contain("├─◈")
      out.should contain("└─◈")
    end
  end
end
