require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/modules/portscan"
require "../../src/nokizaru/context"

# Returns a fixed set of open ports regardless of input, so the result-shaping
# and tarpit classification can be tested without 25+ real listeners.
private class FakeScanner < Nokizaru::Portscan::Scanner
  def initialize(@canned : Array(Nokizaru::Portscan::OpenPort))
  end

  def scan(ip : String, entries : Array({Int32, String}), options : Nokizaru::Portscan::Options, on_progress : Proc(Int32, Int32, Nil)? = nil) : Array(Nokizaru::Portscan::OpenPort)
    @canned
  end
end

describe Nokizaru::Modules::PortScan do
  describe ".port_entries" do
    it "uses the PORT_LIST for the default spec" do
      entries = Nokizaru::Modules::PortScan.port_entries(nil)
      entries.size.should eq(Nokizaru::Modules::PortScan::PORT_LIST.size)
      entries.should contain({80, "HTTP"})
    end

    it "expands the all spec to every port" do
      Nokizaru::Modules::PortScan.port_entries("all").size.should eq(65_535)
    end

    it "parses a custom list and range, naming unknown ports" do
      Nokizaru::Modules::PortScan.port_entries("443,80,8000-8001").should eq(
        [{80, "HTTP"}, {443, "HTTPS"}, {8000, "HTTP-Alt"}, {8001, "unknown"}]
      )
    end

    it "rejects an out-of-range port and a descending range" do
      expect_raises(ArgumentError) { Nokizaru::Modules::PortScan.port_entries("99999") }
      expect_raises(ArgumentError) { Nokizaru::Modules::PortScan.port_entries("100-50") }
    end
  end

  describe ".collect" do
    it "scans a loopback port and shapes the full record" do
      listener = TCPServer.new("127.0.0.1", 0)
      open_port = listener.local_address.port
      closed_port = HttpTestServer.closed_port
      begin
        result = Nokizaru::Modules::PortScan.collect("127.0.0.1", 4, "#{open_port},#{closed_port}")

        result.total_ports.should eq(2)
        result.network_shape.should eq("normal")
        result.shape_confidence.should eq("medium")
        result.shape_reason.should be_nil
        result.open_ports.should eq(["#{open_port} (unknown)"])

        result.ports.size.should eq(1)
        record = result.ports.first
        record.ip.should eq("127.0.0.1")
        record.port.should eq(open_port)
        record.protocol.should eq("tcp")
        record.state.should eq("open")
        record.service.should eq("unknown")
        record.source.should eq("tcp_connect")
        record.confidence.should eq("confirmed")
        record.latency_ms.should be >= 0.0
        record.category.should eq("unknown")
        record.tls_likely?.should be_false
        record.http_likely?.should be_false
        record.exposure.should eq("standard")
        record.enrichment.should eq("port_metadata")
      ensure
        listener.close
      end
    end

    it "reports live scan progress to the rail" do
      listener = TCPServer.new("127.0.0.1", 0)
      open_port = listener.local_address.port
      closed_port = HttpTestServer.closed_port
      reports = [] of String
      progress = Nokizaru::ProgressReporter.new(->(_stage : String, detail : String) { reports << detail; nil })
      begin
        Nokizaru::Modules::PortScan.collect("127.0.0.1", 4, "#{open_port},#{closed_port}", progress: progress)
        reports.size.should eq(2) # one per probe
        reports.any?(&.matches?(/\A2\/2 open \d+\z/)).should be_true
      ensure
        listener.close
      end
    end

    it "classifies a broad low-variance scan as a tarpit and downgrades non-web ports" do
      canned = Nokizaru::Modules::PortScan::PORT_LIST.first(90).map do |(port, name)|
        Nokizaru::Portscan::OpenPort.new(port, name, 5.0)
      end
      result = Nokizaru::Modules::PortScan.collect("10.0.0.1", 4, nil, FakeScanner.new(canned))

      result.network_shape.should eq("all_open_or_tarpit")
      result.shape_confidence.should eq("high")
      result.shape_reason.not_nil!.should contain("latency variance")

      web = result.ports.find! { |r| r.port == 80 }
      web.confidence.should eq("confirmed") # web ports keep confidence
      ssh = result.ports.find! { |r| r.port == 22 }
      ssh.confidence.should eq("low")
      ssh.exposure.should eq("unverified")
      ssh.enrichment.should eq("port_metadata_tarpit_shape")

      result.artifact_ports.should eq(["80", "443"]) # only the non-downgraded web ports
    end
  end

  describe "run-state wiring" do
    it "stores the result on modules.portscan under the \"portscan\" key" do
      meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-10-20T00:00:00Z")
      run = Nokizaru::RunState.new(meta)
      record = Nokizaru::Portscan::PortRecord.build("1.2.3.4", Nokizaru::Portscan::OpenPort.new(443, "HTTPS", 1.5))
      run.modules.portscan = Nokizaru::Modules::PortScan::Result.new(["443 (HTTPS)"], [record], 1, "normal", "medium")

      run.modules.portscan.should_not be_nil
      json = JSON.parse(run.to_json)["modules"]["portscan"]
      json["network_shape"].as_s.should eq("normal")
      json["ports"][0]["port"].as_i.should eq(443)
      json["ports"][0]["tls_likely"].as_bool.should be_true
    end
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

describe "Nokizaru::Modules::PortScan.present" do
  it "renders the open ports and a completion line" do
    result = Nokizaru::Modules::PortScan::Result.new(
      ["80 (http)", "443 (https)"], [] of Nokizaru::Portscan::PortRecord, 100, "normal", "high", nil)
    text = present_capture { Nokizaru::Modules::PortScan.present(result) }
    text.should contain("80 (http)")
    text.should contain("443 (https)")
    text.should contain("Scan completed!")
  end
end
