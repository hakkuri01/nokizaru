require "../spec_helper"
require "../../src/nokizaru/tui/app"

private alias App = Nokizaru::Tui::App
private alias Form = Nokizaru::Tui::Form
private alias Profile = Nokizaru::Tui::Profile
private alias M = Nokizaru::Tui::Messages

private BANNER = ["BANNER-ART"]

private def app(opening = false) : App
  App.new(Form.new, BANNER, 0.0, opening: opening)
end

private def key(app, name)
  app.update(M::Key.new(name))
end

private def profile : Profile
  Profile.new(target: "https://x", ip: "1.2.3.4", modules: "full",
    switches: "none", modules_enabled: ["headers", "dns"])
end

describe Nokizaru::Tui::App do
  describe "opening screen" do
    it "advances the reveal on a tick and stays animating until the hold" do
      a = app(opening: true)
      a.update(M::Tick.new(0.3, nil, {} of String => String)).should be_empty
      a.animating?.should be_true
      a.screen.opening?.should be_true
    end

    it "opens the form on any key and quits on ctrl+c" do
      a = app(opening: true)
      key(a, "x").should be_empty
      a.screen.form?.should be_true

      b = app(opening: true)
      key(b, "ctrl+c").should eq([App::Command::Quit])
    end
  end

  describe "form screen" do
    it "launches a scan once a target and module are set" do
      a = app
      key(a, "i")
      "x.com".each_char { |ch| key(a, ch.to_s) }
      key(a, "esc")
      key(a, "enter").should be_empty # no module yet
      key(a, "j")                     # to the Modules field
      key(a, " ")                     # select Full
      key(a, "enter").should eq([App::Command::RunScan])
      a.form.launching?.should be_true
    end

    it "opens help, and quits" do
      a = app
      key(a, "h")
      a.screen.help?.should be_true

      key(app, "q").should eq([App::Command::Quit])
      key(app, "ctrl+c").should eq([App::Command::Quit])
    end
  end

  describe "help screen" do
    it "scrolls within bounds and returns to the form" do
      a = app
      key(a, "h")
      key(a, "k").should be_empty # already at top, clamped
      key(a, "j")
      key(a, "q")
      a.screen.form?.should be_true
    end
  end

  describe "launch outcomes" do
    it "opens the dashboard when the scan goes live" do
      a = app
      a.update(M::ScanStarted.new(profile)).should be_empty
      a.screen.dashboard?.should be_true
      a.dashboard.should_not be_nil
    end

    it "returns to the form with the reason on an abort" do
      a = app
      a.update(M::ScanAborted.new("could not resolve target"))
      a.screen.form?.should be_true
      a.form.error.should eq("could not resolve target")
    end

    it "returns to the form on a failure raised before the scan went live" do
      a = app
      a.form.launching = true
      a.update(M::ScanFailed.new("boom"))
      a.screen.form?.should be_true
      a.form.error.should eq("boom")
    end
  end

  describe "dashboard screen" do
    it "stops back to the form on q and quits on ctrl+c, else delegates keys" do
      a = app
      a.update(M::ScanStarted.new(profile))
      key(a, "tab").should be_empty # delegated to the dashboard
      key(a, "q").should eq([App::Command::StopAndForm])
      key(a, "ctrl+c").should eq([App::Command::Quit])
    end
  end

  describe "power-user launch" do
    it "opens straight on the dashboard" do
      a = App.new(Form.new, BANNER, 0.0, launch: profile)
      a.screen.dashboard?.should be_true
      a.dashboard.should_not be_nil
    end

    it "steps back to the prefilled form on q, and a second q quits (the qq quick-exit)" do
      a = App.new(Form.new, BANNER, 0.0, launch: profile)
      key(a, "q").should eq([App::Command::StopAndForm]) # back to the form
      a.enter_form                                       # the program performs the transition
      a.screen.form?.should be_true
      key(a, "q").should eq([App::Command::Quit]) # second q exits
    end

    it "always hard-quits on ctrl+c" do
      a = App.new(Form.new, BANNER, 0.0, launch: profile)
      key(a, "ctrl+c").should eq([App::Command::Quit])
    end
  end

  describe "resize and rendering" do
    it "tracks a new size and keeps the form in step" do
      a = app
      a.update(M::Resize.new(120, 40))
      a.cols.should eq(120)
      a.rows.should eq(40)
      a.form.cols.should eq(120)
    end

    it "renders a frame for the current screen" do
      a = app(opening: true)
      a.view.size.should be > 0
      key(a, "x") # to form
      a.view.size.should be > 0
    end

    it "exposes the launch options" do
      a = app
      key(a, "i")
      "example.com".each_char { |ch| key(a, ch.to_s) }
      key(a, "esc")
      a.scan_options.target.should eq("example.com")
    end

    it "tracks dirtiness for the render loop" do
      a = app(opening: true)
      a.dirty?.should be_true
      a.clean!
      a.dirty?.should be_true # the opening still animates
      key(a, "x")             # to the form
      a.clean!
      a.dirty?.should be_false
      key(a, "j")
      a.dirty?.should be_true
    end
  end
end
