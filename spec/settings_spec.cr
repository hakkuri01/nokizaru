require "./spec_helper"
require "file_utils"
require "../src/nokizaru/settings"

private def with_tmp(&)
  tmp = File.join(Dir.tempdir, "nkz-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(tmp)
  yield File.join(tmp, "config.json")
ensure
  FileUtils.rm_rf(tmp) if tmp && Dir.exists?(tmp)
end

describe Nokizaru::Settings do
  it "exposes the built-in defaults" do
    s = Nokizaru::Settings.new
    s.common.timeout.should eq(30.0)
    s.common.dns_servers.should contain("8.8.8.8")
    s.ssl_cert.ssl_port.should eq(443)
    s.port_scan.threads.should eq(50)
    s.dir_enum.threads.should eq(50)
    s.dir_enum.redirect?.should be_false
    s.dir_enum.extension.should eq("")
  end

  it "writes and returns defaults when no config exists" do
    with_tmp do |path|
      s = Nokizaru::Settings.load(path)
      s.common.timeout.should eq(30.0)
      File.exists?(path).should be_true
    end
  end

  it "loads values from an existing config, filling missing keys with defaults" do
    with_tmp do |path|
      File.write(path, %({"common":{"timeout":5},"dir_enum":{"redirect":true,"extension":"php"}}))
      s = Nokizaru::Settings.load(path)
      s.common.timeout.should eq(5.0)
      s.dir_enum.redirect?.should be_true
      s.dir_enum.extension.should eq("php")
      s.ssl_cert.ssl_port.should eq(443)
    end
  end

  it "backs up and rewrites a malformed config" do
    with_tmp do |path|
      File.write(path, "garbage")
      s = Nokizaru::Settings.load(path)
      s.common.timeout.should eq(30.0)
      Dir.glob("#{path}.bak.*").empty?.should be_false
    end
  end

  it "normalizes a curated size name and passes a custom path through" do
    Nokizaru::Settings.wordlist("LARGE").should eq("large")
    Nokizaru::Settings.wordlist("/tmp/custom.txt").should eq("/tmp/custom.txt")
  end
end
