require "../spec_helper"
require "json"
require "file_utils"
require "../../src/nokizaru/exporters/json"
require "../support/tls_test_server"

private def sample_run : Nokizaru::RunState
  meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-08-29T00:00:00Z")
  run = Nokizaru::RunState.new(meta)
  run.add_artifact("subdomains", ["a.example.com", "b.example.com"])
  run.findings << Nokizaru::Finding.new(
    id: "headers.x", severity: "medium", title: "CSP header missing",
    source_module: "headers", tags: ["headers"], evidence: "no csp",
  )
  run
end

private def with_tmpdir(&)
  dir = File.tempname("nokizaru-json-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Nokizaru::Exporters::Json do
  it "preserves the collected TLS cipher tuple in the on-disk run export" do
    TlsTestServer.with_server do |host, port|
      run = sample_run
      result = Nokizaru::Modules::SSLInfo.collect(host, port)
      result.success?.should be_true
      run.modules.sslinfo = result
      with_tmpdir do |dir|
        path = File.join(dir, "report.json")
        Nokizaru::Exporters::Json.write(run, path)
        cipher = JSON.parse(File.read(path))["modules"]["sslinfo"]["cert"]["cipher"].as_a
        expected = result.cert.not_nil!.cipher.not_nil!
        cipher.size.should eq(4)
        cipher[0].as_s.should eq(expected[0])
        cipher[1].as_s.should eq(expected[1])
        cipher[2].as_i.should eq(expected[2])
        cipher[3].as_i.should eq(expected[3])
      end
    end
  end

  it "writes the typed run as pretty JSON matching the Ruby run shape" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.json")
      Nokizaru::Exporters::Json.write(sample_run, path)
      parsed = JSON.parse(File.read(path))

      parsed["meta"]["target"].as_s.should eq("https://example.com")
      parsed["modules"].as_h.empty?.should be_true
      parsed["artifacts"]["subdomains"].as_a.map(&.as_s).should eq(["a.example.com", "b.example.com"])
      parsed["findings"][0]["module"].as_s.should eq("headers")
      parsed["findings"][0].as_h.has_key?("recommendation").should be_false
    end
  end

  it "pretty-prints with two-space indentation" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.json")
      Nokizaru::Exporters::Json.write(sample_run, path)
      File.read(path).should contain("\n  \"meta\": {")
    end
  end

  it "writes the export owner-only" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.json")
      Nokizaru::Exporters::Json.write(sample_run, path)
      (File.info(path).permissions.value & 0o777).to_s(8).should eq("600")
    end
  end
end
