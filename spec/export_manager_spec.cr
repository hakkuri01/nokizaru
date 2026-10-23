require "./spec_helper"
require "json"
require "file_utils"
require "../src/nokizaru/export_manager"

private def sample_run : Nokizaru::RunState
  meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-08-29T00:00:00Z")
  Nokizaru::RunState.new(meta)
end

private def with_tmpdir(&)
  dir = File.tempname("nokizaru-export-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def mode_octal(path : String) : String
  (File.info(path).permissions.value & 0o777).to_s(8)
end

describe Nokizaru::ExportManager do
  it "writes each supported format to a custom destination" do
    with_tmpdir do |dir|
      paths = Nokizaru::ExportManager.new.export(
        sample_run, domain: "example.com", formats: %w[txt json html],
        custom_directory: dir, custom_basename: "report",
      )

      paths.keys.sort!.should eq(%w[html json txt])
      paths.each_value { |path| File.file?(path).should be_true }
      JSON.parse(File.read(paths["json"]))["meta"]["target"].as_s.should eq("https://example.com")
    end
  end

  it "defaults to a txt export when no format is given" do
    with_tmpdir do |dir|
      paths = Nokizaru::ExportManager.new.export(
        sample_run, domain: "example.com", formats: [] of String,
        custom_directory: dir, custom_basename: "report",
      )
      paths.keys.should eq(%w[txt])
    end
  end

  it "rejects unsupported formats" do
    expect_raises(ArgumentError) do
      Nokizaru::ExportManager.new.export(sample_run, domain: "example.com", formats: %w[xml])
    end
  end

  it "requires the export filename to be a plain name and writes nothing otherwise" do
    with_tmpdir do |dir|
      nested = File.join(dir, "out")
      ["../../keys", "sub/report", "..", ".hidden", "a\\b"].each do |name|
        expect_raises(ArgumentError) do
          Nokizaru::ExportManager.new.export(
            sample_run, domain: "example.com", formats: %w[json],
            custom_directory: nested, custom_basename: name,
          )
        end
      end
      Dir.glob(File.join(dir, "**", "*.json")).should be_empty
    end
  end

  it "writes exports and any directory it creates owner-only" do
    with_tmpdir do |dir|
      target = File.join(dir, "new-exports")
      paths = Nokizaru::ExportManager.new.export(
        sample_run, domain: "example.com", formats: %w[txt json html],
        custom_directory: target, custom_basename: "report",
      )

      paths.each_value { |path| mode_octal(path).should eq("600") }
      mode_octal(target).should eq("700")
    end
  end

  it "checks everything before a long scan and writes nothing in prepare" do
    with_tmpdir do |dir|
      target = File.join(dir, "later")
      manager = Nokizaru::ExportManager.new

      expect_raises(ArgumentError) do
        manager.prepare(domain: "example.com", formats: %w[jsno], custom_directory: target)
      end
      Dir.exists?(target).should be_false

      manager.prepare(domain: "example.com", formats: %w[json], custom_directory: target)
      Dir.children(target).should be_empty
    end
  end
end
