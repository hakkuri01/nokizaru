require "../spec_helper"
require "../../src/nokizaru/context"
require "json"

private WAPPALYZER_BODY = <<-JSON
  [
    {"technologies": [
      {"name": "nginx", "version": "1.2", "categories": [{"id": 22, "name": "Web servers"}]},
      {"name": "nginx", "version": "", "categories": ["Reverse proxies"]},
      {"name": "React", "version": "18", "categories": [{"name": "JavaScript frameworks"}]},
      {"name": "", "version": "x", "categories": []}
    ]}
  ]
  JSON

describe Nokizaru::Modules::Arch do
  describe "Parser.parse" do
    it "extracts, merges, and sorts technologies" do
      techs = Nokizaru::Modules::Arch::Parser.parse(WAPPALYZER_BODY)
      techs.map(&.name).should eq(["nginx", "React"])

      nginx = techs.first
      nginx.version.should eq("1.2")
      nginx.categories.should eq(["Web servers", "Reverse proxies"])
      techs[1].version.should eq("18")
      techs[1].categories.should eq(["JavaScript frameworks"])
    end

    it "handles a single object and malformed JSON" do
      Nokizaru::Modules::Arch::Parser.parse(%({"technologies":[{"name":"Vue"}]})).map(&.name).should eq(["Vue"])
      Nokizaru::Modules::Arch::Parser.parse("not json").should be_empty
    end
  end

  describe ".request_url" do
    it "carries the target as the urls query parameter" do
      url = Nokizaru::Modules::Arch.request_url("https://example.com/a")
      url.should start_with("https://api.wappalyzer.com/v2/lookup/?urls=")
      url.should contain("example.com")
    end
  end

  describe ".collect" do
    it "skips without an API key and makes no request" do
      pool = Nokizaru::Http::Pool.new
      Nokizaru::Modules::Arch.collect("https://example.com", pool, nil, 10.0).status.should eq("skipped_no_key")
      Nokizaru::Modules::Arch.collect("https://example.com", pool, "   ", 10.0).status.should eq("skipped_no_key")
    end
  end

  it "serializes under the architecture_fingerprinting run key" do
    meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "t")
    run = Nokizaru::RunState.new(meta)
    run.modules.arch = Nokizaru::Modules::Arch::Result.ok(Nokizaru::Modules::Arch::Parser.parse(WAPPALYZER_BODY))
    run.modules.arch.should_not be_nil
    JSON.parse(run.to_json)["modules"]["architecture_fingerprinting"]["status"].as_s.should eq("ok")
  end
end

private def present_capture(&)
  io = IO::Memory.new
  Nokizaru::UI.output = io
  yield
  Nokizaru::TerminalText.strip_sgr(io.to_s)
ensure
  Nokizaru::UI.output = STDOUT
end

describe "Nokizaru::Modules::Arch.present" do
  it "renders the technologies with version and categories" do
    techs = [
      Nokizaru::Modules::Arch::Technology.new("nginx", "1.25", ["Web servers"]),
      Nokizaru::Modules::Arch::Technology.new("React", "", ["JavaScript frameworks"]),
    ]
    text = present_capture { Nokizaru::Modules::Arch.present(Nokizaru::Modules::Arch::Result.ok(techs)) }
    text.should contain("nginx (version: 1.25 | categories: Web servers)")
    text.should contain("React (categories: JavaScript frameworks)")
    text.should contain("Total Unique Technologies Found")
  end

  it "reports a missing API key and an empty result" do
    present_capture { Nokizaru::Modules::Arch.present(Nokizaru::Modules::Arch::Result.skipped) }
      .should contain("API key not found!")
    present_capture { Nokizaru::Modules::Arch.present(Nokizaru::Modules::Arch::Result.ok([] of Nokizaru::Modules::Arch::Technology)) }
      .should contain("No technologies identified")
  end
end
