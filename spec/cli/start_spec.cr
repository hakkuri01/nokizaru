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
