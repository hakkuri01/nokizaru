require "../spec_helper"
require "../../src/nokizaru/cli/options"

describe Nokizaru::CLI::Options do
  it "parses the full flag surface, normalizing multi-char short flags" do
    argv = [
      "--target", "https://example.com", "--full", "--export",
      "-nb", "-dt", "20", "-pt", "40", "-sp", "8443", "-p", "80,443",
      "-T", "2.5", "-w", "large", "-H", "A: 1", "-H", "B: 2", "-r", "--insecure",
      "-d", "1.1.1.1", "-e", "php,txt", "-o", "json,txt", "-cd", "/tmp/out", "-of", "scan", "-k", "shodan",
    ]
    opts = Nokizaru::CLI::Options.parse(argv)
    opts.target.should eq("https://example.com")
    opts.full?.should be_true
    opts.export?.should be_true
    opts.nb?.should be_true
    opts.dir_threads.should eq(20)
    opts.port_threads.should eq(40)
    opts.ssl_port.should eq(8443)
    opts.ports.should eq("80,443")
    opts.timeout.should eq(2.5)
    opts.wordlist.should eq("large")
    opts.request_headers.should eq(["A: 1", "B: 2"])
    opts.redirects.should be_true
    opts.insecure?.should be_true
    opts.dns_servers.should eq("1.1.1.1")
    opts.extensions.should eq("php,txt")
    opts.formats.should eq("json,txt")
    opts.export_dir.should eq("/tmp/out")
    opts.export_basename.should eq("scan")
    opts.key.should eq("shodan")
  end

  it "accepts the =value form for a normalized short flag" do
    Nokizaru::CLI::Options.parse(["-dt=15"]).dir_threads.should eq(15)
  end

  %w[-dt -pt -sp].each do |flag|
    ["", "nope", "12oops", "1.5", "2147483648", "-2147483649", "NaN", "inf"].each do |value|
      it "rejects #{flag}=#{value.inspect} as an option error" do
        expect_raises(OptionParser::InvalidOption, "#{flag} must be a 32-bit integer") do
          Nokizaru::CLI::Options.parse(["#{flag}=#{value}"])
        end
      end
    end
  end

  ["", "nope", "12oops", "NaN", "nan", "inf", "-inf", "Infinity", "1e999", "1e100", "2e18"].each do |value|
    it "rejects -T #{value.inspect} as an option error" do
      expect_raises(OptionParser::InvalidOption, "-T must be a finite timeout within the runtime range") do
        Nokizaru::CLI::Options.parse(["-T", value])
      end
    end
  end

  it "leaves nonpositive numbers for runtime validation" do
    [-1, 0].each do |value|
      opts = Nokizaru::CLI::Options.parse(["-dt=#{value}", "-pt=#{value}", "-sp=#{value}", "-T", value.to_s])
      opts.dir_threads.should eq(value)
      opts.port_threads.should eq(value)
      opts.ssl_port.should eq(value)
      opts.timeout.should eq(value.to_f)
    end
  end

  it "accepts representable integer boundaries and finite fractional timeouts" do
    opts = Nokizaru::CLI::Options.parse(["-dt=2147483647", "-pt=-2147483648", "-sp=65536", "-T", "1e-3"])
    opts.dir_threads.should eq(Int32::MAX)
    opts.port_threads.should eq(Int32::MIN)
    opts.ssl_port.should eq(65536)
    opts.timeout.should eq(0.001)
  end

  it "leaves the tri-state redirect flag nil and TLS verification on when unset" do
    opts = Nokizaru::CLI::Options.parse(["--headers"])
    opts.redirects.should be_nil
    opts.insecure?.should be_false
  end

  it "selects modules from flags in execution order" do
    Nokizaru::CLI::Options.parse(["--dir", "--headers"]).enabled_modules.should eq(["headers", "dir"])
  end

  it "runs every module under --full" do
    Nokizaru::CLI::Options.parse(["--full"]).enabled_modules.should eq(Nokizaru::CLI::Options::MODULE_ORDER)
  end

  it "drops a module skipped with --no-<module> under --full" do
    enabled = Nokizaru::CLI::Options.parse(["--full"]).skips
    opts = Nokizaru::CLI::Options.parse(["--full", "--no-dir", "--no-ps"])
    opts.enabled_modules.includes?("dir").should be_false
    opts.enabled_modules.includes?("ps").should be_false
    opts.enabled_modules.includes?("headers").should be_true
    enabled.should be_empty
  end

  it "raises on an unknown flag" do
    expect_raises(OptionParser::InvalidOption) { Nokizaru::CLI::Options.parse(["--bogus"]) }
  end

  it "parses --headless and refuses it alongside --tui" do
    Nokizaru::CLI::Options.parse(["--headless", "--dir"]).headless?.should be_true
    Nokizaru::CLI::Options.parse(["--dir"]).headless?.should be_false
    expect_raises(OptionParser::Exception, "--headless and --tui cannot be combined") do
      Nokizaru::CLI::Options.parse(["--headless", "--tui"])
    end
  end
end
