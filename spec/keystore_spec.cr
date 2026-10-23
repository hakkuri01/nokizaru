require "./spec_helper"
require "file_utils"
require "../src/nokizaru/keystore"

private def with_data_home(&)
  tmp = File.join(Dir.tempdir, "nkz-#{Random::Secure.hex(6)}")
  previous = ENV["XDG_DATA_HOME"]?
  ENV["XDG_DATA_HOME"] = tmp
  yield
ensure
  previous ? (ENV["XDG_DATA_HOME"] = previous) : ENV.delete("XDG_DATA_HOME")
  FileUtils.rm_rf(tmp) if tmp && Dir.exists?(tmp)
end

describe Nokizaru::KeyStore do
  it "knows valid key names" do
    Nokizaru::KeyStore.valid_name?("shodan").should be_true
    Nokizaru::KeyStore.valid_name?("censys_api_id").should be_true
    Nokizaru::KeyStore.valid_name?("nope").should be_false
  end

  it "saves a key atomically and reads it back" do
    with_data_home do
      Nokizaru::KeyStore.save("shodan", "abc123")
      Nokizaru::KeyStore.fetch("shodan").should eq("abc123")
      File.info(Nokizaru::Paths.keys_file).permissions.should eq(File::Permissions.new(0o600))
    end
  end

  it "prefers an environment variable over the stored key" do
    with_data_home do
      Nokizaru::KeyStore.save("shodan", "stored")
      ENV["NK_SHODAN_KEY"] = "fromenv"
      Nokizaru::KeyStore.fetch("shodan", env: "NK_SHODAN_KEY").should eq("fromenv")
    ensure
      ENV.delete("NK_SHODAN_KEY")
    end
  end

  it "falls back to the stored key when the env var is empty or unset" do
    with_data_home do
      Nokizaru::KeyStore.save("shodan", "stored")
      Nokizaru::KeyStore.fetch("shodan", env: "NK_SHODAN_KEY").should eq("stored")
      Nokizaru::KeyStore.fetch("missing").should be_nil
    end
  end

  it "refuses to overwrite an unparseable store" do
    with_data_home do
      File.write(Nokizaru::Paths.keys_file, "not json")
      expect_raises(Nokizaru::KeyStore::UnreadableStore) do
        Nokizaru::KeyStore.save("shodan", "x")
      end
    end
  end
end
