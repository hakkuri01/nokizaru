require "../spec_helper"
require "file_utils"
require "../../src/nokizaru/cli/key_saver"

private def ui_silent(&)
  sink = IO::Memory.new
  Nokizaru::UI.output = sink
  yield sink
ensure
  Nokizaru::UI.output = STDOUT
end

private def with_data_home(&)
  tmp = File.join(Dir.tempdir, "nkz-#{Random::Secure.hex(6)}")
  previous = ENV["XDG_DATA_HOME"]?
  ENV["XDG_DATA_HOME"] = tmp
  yield
ensure
  previous ? (ENV["XDG_DATA_HOME"] = previous) : ENV.delete("XDG_DATA_HOME")
  FileUtils.rm_rf(tmp) if tmp && Dir.exists?(tmp)
end

describe Nokizaru::CLI::KeySaver do
  it "saves a name@value key and returns success" do
    with_data_home do
      ui_silent do
        code = Nokizaru::CLI::KeySaver.run("shodan@abc123", interactive: false, input: IO::Memory.new)
        code.should eq(0)
        Nokizaru::KeyStore.fetch("shodan").should eq("abc123")
      end
    end
  end

  it "reads a name-only key from piped input" do
    with_data_home do
      ui_silent do
        code = Nokizaru::CLI::KeySaver.run("shodan", interactive: false, input: IO::Memory.new("piped-key\n"))
        code.should eq(0)
        Nokizaru::KeyStore.fetch("shodan").should eq("piped-key")
      end
    end
  end

  it "rejects an invalid key name without saving" do
    with_data_home do
      ui_silent do |sink|
        Nokizaru::CLI::KeySaver.run("bogus@x", interactive: false, input: IO::Memory.new).should eq(1)
        sink.to_s.should contain("Invalid key name")
      end
    end
  end

  it "rejects an empty value as invalid syntax" do
    with_data_home do
      ui_silent do
        Nokizaru::CLI::KeySaver.run("shodan@", interactive: false, input: IO::Memory.new).should eq(1)
      end
    end
  end

  it "refuses to clobber an unreadable store" do
    with_data_home do
      ui_silent do
        File.write(Nokizaru::Paths.keys_file, "not json")
        Nokizaru::CLI::KeySaver.run("shodan@x", interactive: false, input: IO::Memory.new).should eq(1)
      end
    end
  end
end
