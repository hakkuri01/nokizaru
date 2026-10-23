require "../spec_helper"
require "../../src/nokizaru/tui/program"

private alias Program = Nokizaru::Tui::Program
private alias Terminal = Nokizaru::Tui::Terminal
private alias App = Nokizaru::Tui::App
private alias Form = Nokizaru::Tui::Form
private alias Profile = Nokizaru::Tui::Profile
private alias Progress = Nokizaru::Tui::Progress
private alias Feed = Nokizaru::Tui::Feed

# A stand-in controller: no scan, an idle wake channel, and empty observations.
private class FakeController
  getter wake_channel : Channel(Nil)
  getter stopped : Int32

  def initialize
    @wake_channel = Channel(Nil).new(1)
    @stopped = 0
    @feed = Feed.new(-> { nil.as(String?) })
  end

  def run_scan(app) : Nil
  end

  def stop_scan : Nil
    @stopped += 1
  end

  def scanning? : Bool
    false
  end

  def observe : Tuple(Progress::Snapshot?, Hash(String, String))
    {nil, {} of String => String}
  end

  def feed : Feed?
    @feed
  end
end

# Runs a program over a pipe-backed terminal with the given input preloaded,
# capturing the rendered output (SGR stripped) and yielding it with the program
# and controller. The output pipe is drained on a fiber so the loop never blocks
# on a full pipe, and closed once the loop exits so the drain reaches EOF.
private def run_program(input : String, app : App? = nil, &)
  input_r, input_w = IO.pipe
  output_r, output_w = IO.pipe
  sink = IO::Memory.new
  drained = Channel(Nil).new(1)
  spawn do
    IO.copy(output_r, sink)
  rescue IO::Error
  ensure
    drained.send(nil)
  end
  input_w.print(input) unless input.empty?
  input_w.close
  controller = FakeController.new
  app ||= App.new(Form.new, ["BANNER"], 0.0, opening: false)
  program = Program.new(app, Terminal.new(input_r, output_w), controller, -> { 0.0 })
  program.run
  output_w.close
  drained.receive
  yield program, controller, Nokizaru::TerminalText.strip_sgr(sink.to_s)
ensure
  {input_r, input_w, output_r, output_w}.each do |io|
    io.try { |fd| fd.close unless fd.closed? }
  end
end

private def power_user_app : App
  profile = Profile.new(target: "https://power.example", ip: "1.2.3.4", modules: "Headers",
    switches: "none", modules_enabled: ["headers"])
  App.new(Form.new, ["BANNER"], 0.0, launch: profile)
end

describe Nokizaru::Tui::Program do
  it "quits cleanly when the form receives q" do
    run_program("q") do |program, controller|
      program.signal_status.should be_nil
      controller.stopped.should be > 0
    end
  end

  it "quits on a ctrl+c byte" do
    run_program("\u0003") do |program, _controller|
      program.signal_status.should be_nil
    end
  end

  it "quits when the terminal closes (EOF)" do
    run_program("") do |program, _controller|
      program.signal_status.should be_nil
    end
  end

  it "opens straight on the dashboard for a power-user launch and renders the target" do
    run_program("qq", app: power_user_app) do |program, _controller, output|
      program.signal_status.should be_nil            # qq exits cleanly
      output.should contain("https://power.example") # the dashboard HUD rendered
    end
  end

  it "hard-quits a power-user dashboard on ctrl+c" do
    run_program("\u0003", app: power_user_app) do |program, _controller, _output|
      program.signal_status.should be_nil
    end
  end
end
