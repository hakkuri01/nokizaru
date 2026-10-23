require "../spec_helper"
require "../../src/nokizaru/tui/form"

private alias Form = Nokizaru::Tui::Form
private alias Options = Nokizaru::CLI::Options

private def type(form, text)
  text.each_char { |ch| form.key(ch.to_s) }
end

private def prefilled : Form
  opts = Options.new
  opts.target = "https://example.com"
  opts.full = true
  opts.wordlist = "large"
  opts.export = true
  opts.request_headers << "Cookie: secret"
  opts.skips << "wayback"
  opts.ssl_port = 8443
  opts.dns_servers = "1.1.1.1"
  Form.new(opts)
end

describe Nokizaru::Tui::Form do
  describe "vim editing" do
    it "starts in NORMAL at the first field and is not ready without a target or module" do
      form = Form.new
      form.insert?.should be_false
      form.focus.should eq(0)
      form.ready?.should be_false
    end

    it "edits the focused text field in INSERT and leaves on esc" do
      form = Form.new
      form.key("i")
      form.insert?.should be_true
      type(form, "example.com")
      form.text("target").should eq("example.com")
      form.key("backspace")
      form.text("target").should eq("example.co")
      form.key("esc")
      form.insert?.should be_false
    end

    it "rejects non-numeric input in a number field" do
      form = Form.new
      7.times { form.key("j") } # to the Timeout field
      form.key("i")
      form.key("a")
      form.text("T").should eq("")
      type(form, "30")
      form.text("T").should eq("30")
    end

    it "toggles a switch field with space" do
      form = Form.new
      8.times { form.key("j") } # to Follow Redirects
      form.key(" ")
      form.toggle?("r").should be_true
      form.key(" ")
      form.toggle?("r").should be_false
    end

    it "picks modules from the chip row" do
      form = Form.new
      form.key("j") # to the Modules field
      form.key(" ") # chip 0 is Full
      form.module_on?("full").should be_true
      form.key("right") # chip 1 is Headers
      form.key(" ")
      form.module_on?("headers").should be_true
    end
  end

  describe "#key actions" do
    it "returns Help, Quit, and Run outcomes" do
      form = Form.new
      form.key("h").should eq(Form::Action::Help)
      form.key("q").should eq(Form::Action::Quit)
    end

    it "runs only when a target and a module are set" do
      form = Form.new
      form.key("i")
      type(form, "x.com")
      form.key("esc")
      form.key("enter").should be_nil # no module yet
      form.key("j")
      form.key(" ") # select Full
      form.key("enter").should eq(Form::Action::Run)
    end

    it "ignores keys while launching" do
      form = prefilled
      form.launching = true
      form.key("q").should be_nil
    end
  end

  describe "prefill and #to_options" do
    it "reflects the invocation options in the fields" do
      form = prefilled
      form.text("target").should eq("https://example.com")
      form.module_on?("full").should be_true
      form.text("w").should eq("large")
      form.toggle?("export").should be_true
      form.ready?.should be_true
    end

    it "rebuilds the typed options a scan runs with, carrying headers/skips/-sp/-d" do
      result = prefilled.to_options
      result.target.should eq("https://example.com")
      result.full?.should be_true
      result.wordlist.should eq("large")
      result.export?.should be_true
      result.request_headers.should eq(["Cookie: secret"])
      result.skips.includes?("wayback").should be_true
      result.ssl_port.should eq(8443)
      result.dns_servers.should eq("1.1.1.1")
    end
  end

  describe "#command_segments" do
    it "shows the live command and only a header count, never values" do
      texts = prefilled.command_segments.map(&.[0])
      texts.should contain("--full")
      texts.should contain("--target")
      texts.should contain("https://example.com")
      texts.should contain("--no-wayback")
      texts.should contain("-sp")
      texts.should contain("-H ×1")
      texts.join(" ").should_not contain("secret")
    end
  end

  describe "#resize" do
    it "updates the terminal dimensions" do
      form = Form.new
      form.resize(120, 40)
      form.cols.should eq(120)
      form.rows.should eq(40)
    end
  end
end
