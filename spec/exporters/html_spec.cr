require "../spec_helper"
require "file_utils"
require "../../src/nokizaru/exporters/html"

private def run_with_findings : Nokizaru::RunState
  meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-08-29T00:00:00Z")
  run = Nokizaru::RunState.new(meta)
  run.findings << Nokizaru::Finding.new(
    id: "x", severity: "high", title: "Dangerous <script>alert(1)</script>",
    source_module: "headers", tags: ["headers"], evidence: "a & b", recommendation: "fix it",
  )
  run
end

private def with_tmpdir(&)
  dir = File.tempname("nokizaru-html-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Nokizaru::Exporters::Html do
  it "renders the target and a severity badge from the typed tree" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.html")
      Nokizaru::Exporters::Html.write(run_with_findings, path)
      html = File.read(path)

      html.should contain("<title>Nokizaru Report - https://example.com</title>")
      html.should contain(%(<span class="badge sev-high">HIGH</span>))
    end
  end

  it "HTML-escapes untrusted finding text so it cannot inject markup" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.html")
      Nokizaru::Exporters::Html.write(run_with_findings, path)
      html = File.read(path)

      html.should_not contain("<script>alert(1)</script>")
      html.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
      html.should contain("a &amp; b")
    end
  end

  it "writes the export owner-only" do
    with_tmpdir do |dir|
      path = File.join(dir, "report.html")
      Nokizaru::Exporters::Html.write(run_with_findings, path)
      (File.info(path).permissions.value & 0o777).to_s(8).should eq("600")
    end
  end
end
