require "../spec_helper"
require "../../src/nokizaru/tui/form_view"

private alias Form = Nokizaru::Tui::Form
private alias FormView = Nokizaru::Tui::FormView
private alias Options = Nokizaru::CLI::Options

private def strip(frame)
  Nokizaru::TerminalText.strip_sgr(frame.join("\n"))
end

private def composed_form : Form
  opts = Options.new
  opts.target = "https://example.com"
  opts.full = true
  opts.wordlist = "large"
  opts.export = true
  Form.new(opts)
end

describe Nokizaru::Tui::FormView do
  describe ".frame" do
    it "lists the fields, chips, live command, and NORMAL readout in full mode" do
      form = composed_form
      form.resize(100, 32)
      frame = FormView.frame(form)
      frame.size.should eq(32)
      text = strip(frame)
      text.should contain("Target")
      text.should contain("Modules")
      text.should contain("Wordlist")
      text.should contain("⟦+⟧ Full")
      text.should contain("› nokizaru --full --target https://example.com")
      text.should contain("NORMAL")
      text.should contain("READY")
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 100 }
    end

    it "shows the INSERT readout while editing" do
      form = composed_form
      form.key("i")
      strip(FormView.frame(form)).should contain("INSERT")
    end

    it "surfaces an error and the launching light on the readout" do
      form = composed_form
      form.error = "boom"
      strip(FormView.frame(form)).should contain("boom")
      form.error = nil
      form.launching = true
      strip(FormView.frame(form)).should contain("LAUNCHING")
    end

    it "renders the command from its start in compact mode" do
      form = composed_form
      form.resize(60, 24)
      frame = FormView.frame(form)
      text = strip(frame)
      text.should contain("NOKIZARU")
      text.should contain("› nokizaru")
      frame.each { |row| Nokizaru::TerminalText.width(row).should be <= 60 }
    end

    it "shows the too-small notice below the compact minimum" do
      form = composed_form
      form.resize(40, 10)
      strip(FormView.frame(form)).should contain("Terminal too small")
    end

    it "never writes escape sequences from a hostile prefilled value" do
      opts = Options.new
      opts.target = "https://x.com/\e]52;c;ZXZpbA==\a\e[2J"
      joined = FormView.frame(Form.new(opts)).join
      joined.should_not contain("\e]52")
      joined.should_not contain("\e[2J")
    end
  end
end
