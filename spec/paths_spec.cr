require "./spec_helper"
require "file_utils"
require "../src/nokizaru/paths"

# Runs each case under throwaway XDG dirs so it never touches the real user data
# or config directories.
private def with_xdg(&)
  tmp = File.join(Dir.tempdir, "nkz-#{Random::Secure.hex(6)}")
  prev_data = ENV["XDG_DATA_HOME"]?
  prev_config = ENV["XDG_CONFIG_HOME"]?
  ENV["XDG_DATA_HOME"] = File.join(tmp, "data")
  ENV["XDG_CONFIG_HOME"] = File.join(tmp, "config")
  yield tmp
ensure
  prev_data ? (ENV["XDG_DATA_HOME"] = prev_data) : ENV.delete("XDG_DATA_HOME")
  prev_config ? (ENV["XDG_CONFIG_HOME"] = prev_config) : ENV.delete("XDG_CONFIG_HOME")
  FileUtils.rm_rf(tmp) if tmp && Dir.exists?(tmp)
end

describe Nokizaru::Paths do
  it "resolves owner-private data locations under XDG_DATA_HOME" do
    with_xdg do |tmp|
      data = File.join(tmp, "data", "nokizaru")
      Nokizaru::Paths.user_data_dir.should eq(data)
      Nokizaru::Paths.log_file.should eq(File.join(data, "nokizaru.log"))
      Nokizaru::Paths.keys_file.should eq(File.join(data, "keys.json"))
      Nokizaru::Paths.exports_dir.should eq(File.join(data, "exports"))
      Dir.exists?(data).should be_true
    end
  end

  it "resolves config locations under XDG_CONFIG_HOME" do
    with_xdg do |tmp|
      config = File.join(tmp, "config", "nokizaru")
      Nokizaru::Paths.config_dir.should eq(config)
      Nokizaru::Paths.config_file.should eq(File.join(config, "config.json"))
    end
  end

  it "groups exports under a sanitized per-host directory" do
    with_xdg do |tmp|
      dir = Nokizaru::Paths.target_export_dir("Example.COM")
      dir.should eq(File.join(tmp, "data", "nokizaru", "exports", "example.com"))
      Dir.exists?(dir).should be_true
    end
  end

  it "sanitizes a domain into a safe path segment" do
    Nokizaru::Paths.sanitize_domain_for_path("Example.COM").should eq("example.com")
    Nokizaru::Paths.sanitize_domain_for_path("a/b:c").should eq("a_b_c")
    Nokizaru::Paths.sanitize_domain_for_path("").should eq("unknown")
    Nokizaru::Paths.sanitize_domain_for_path(nil).should eq("unknown")
  end

  it "formats an export timestamp" do
    Nokizaru::Paths.export_timestamp(Time.utc(2026, 10, 20, 7, 8, 9)).should eq("2026-10-20_07-08-09")
  end
end
