require "../spec_helper"
require "../../src/nokizaru/cli/help"

describe Nokizaru::CLI::Help do
  it "renders the usage, sections, and every documented flag" do
    io = IO::Memory.new
    Nokizaru::CLI::Help.render(io)
    out = io.to_s
    out.should contain("usage: nokizaru [-h] [-v] [--target TARGET]")
    out.should contain("[--full] [--no-MODULE]")
    out.should contain("Nokizaru - Recon Refined | v#{Nokizaru::VERSION}")
    out.should contain("Arguments:")
    out.should contain("--target TARGET")
    out.should contain("Extra Options:")
    out.should contain("-H, --header HEADER")
    out.should contain("-k K")
  end

  it "aligns argument rows to a minimum left column width" do
    io = IO::Memory.new
    Nokizaru::CLI::Help.render(io)
    io.to_s.should contain("  --headers          Header Information")
  end

  it "reports the version string" do
    Nokizaru::CLI::Help.version.should eq("nokizaru #{Nokizaru::VERSION}")
  end
end
