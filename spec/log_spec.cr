require "./spec_helper"
require "file_utils"
require "../src/nokizaru/log"

describe Nokizaru::Log do
  it "appends a timestamped line to the log" do
    tmp = File.join(Dir.tempdir, "nkz-#{Random::Secure.hex(6)}")
    previous = ENV["XDG_DATA_HOME"]?
    ENV["XDG_DATA_HOME"] = tmp
    begin
      Nokizaru::Log.write("scan started")
      content = File.read(Nokizaru::Paths.log_file)
      content.should contain("scan started")
      content.should match(/\A\[.+\] scan started/)
    ensure
      previous ? (ENV["XDG_DATA_HOME"] = previous) : ENV.delete("XDG_DATA_HOME")
      FileUtils.rm_rf(tmp) if Dir.exists?(tmp)
    end
  end
end
