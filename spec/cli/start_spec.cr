require "../spec_helper"
require "../../src/nokizaru/cli"

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

describe Nokizaru::CLI do
  describe ".start" do
    it "prints the version and exits 0" do
      io = IO::Memory.new
      status = Nokizaru::CLI.start(["-v"], interactive: false, io: io)
      status.should eq(0)
      io.to_s.should contain(Nokizaru::VERSION)
    end

    it "renders help and exits 0" do
      io = IO::Memory.new
      status = Nokizaru::CLI.start(["--help"], interactive: false, io: io)
      status.should eq(0)
      io.to_s.should contain("usage: nokizaru")
    end

    it "rejects an invalid key name through the key-save flow" do
      status = present_capture { Nokizaru::CLI.start(["-k", "not-a-key"], interactive: false).should eq(1) }
      status.should contain("Invalid key name")
    end

    it "fails a classic scan with no modules selected" do
      status = 0
      text = present_capture { status = Nokizaru::CLI.start(["--target", "https://example.com"], interactive: false) }
      status.should eq(1)
      text.should contain("No Modules")
    end

    it "returns 2 on an unknown option" do
      present_capture { Nokizaru::CLI.start(["--bogus"], interactive: false).should eq(2) }
    end

    describe "--headless" do
      it "runs headless even on a terminal, with every diagnostic on stderr" do
        io = IO::Memory.new
        err = IO::Memory.new
        ui = present_capture do
          Nokizaru::CLI.start(["--headless", "--target", "https://example.com"], interactive: true, io: io, err: err).should eq(1)
        end
        io.to_s.should be_empty
        ui.should be_empty
        err.to_s.should eq("error: No Modules Specified! Use --full or a module flag\n")
      end

      {
        ["--headless", "--bogus"]        => "error: Invalid option: --bogus\n",
        ["--headless", "--tui", "--dir"] => "error: --headless and --tui cannot be combined\n",
      }.each do |argv, expected|
        it "reports #{argv.last} as an option error on stderr with status 2" do
          io = IO::Memory.new
          err = IO::Memory.new
          ui = present_capture { Nokizaru::CLI.start(argv, interactive: false, io: io, err: err).should eq(2) }
          io.to_s.should be_empty
          ui.should be_empty
          err.to_s.should eq(expected)
        end
      end
    end

    {
      "-dt" => %w[nope 2147483648 -2147483649 NaN inf],
      "-pt" => %w[nope 2147483648 -2147483649 NaN inf],
      "-sp" => %w[nope 2147483648 -2147483649 NaN inf],
      "-T"  => %w[nope NaN nan inf -inf Infinity 1e999 1e100 2e18],
    }.each do |flag, values|
      values.each do |value|
        it "returns one actionable line and status 2 for #{flag} #{value}" do
          text = present_capture do
            Nokizaru::CLI.start([flag, value], interactive: false).should eq(2)
          end
          text.lines.size.should eq(1)
          text.should contain("#{flag} must be")
          text.should_not contain("Exception")
          text.should_not contain("ArgumentError")
          text.should_not contain("OverflowError")
          text.should_not contain(".cr:")
          text.should_not contain("/home/")
          text.should_not contain("/nix/store/")
        end
      end
    end
  end
end
