require "../spec_helper"
require "../support/tls_test_server"
require "../support/http_test_server"
require "../../src/nokizaru/context"
require "json"

describe Nokizaru::Modules::SSLInfo do
  it "collects certificate details into the parity-shaped result" do
    TlsTestServer.with_server do |host, port|
      result = Nokizaru::Modules::SSLInfo.collect(host, port)
      result.success?.should be_true
      cert = result.cert.not_nil!
      cert.version.should eq(2)
      cert.serial_number.should eq("4096")
      cert.subject["CN"].should eq("nokizaru.test")
      cert.issuer["CN"].should eq("nokizaru.test")
      cert.subject_alt_name.should eq(["nokizaru.test", "www.nokizaru.test"])
      cert.protocol.not_nil!.should start_with("TLS")
      cert.cipher.should_not be_nil
    end
  end

  it "serializes to the Ruby JSON shape" do
    TlsTestServer.with_server do |host, port|
      json = JSON.parse(Nokizaru::Modules::SSLInfo.collect(host, port).to_json)
      json["cert"]["serialNumber"].as_s.should eq("4096")
      json["cert"]["subjectAltName"].as_a.map(&.as_s).should eq(["nokizaru.test", "www.nokizaru.test"])
      json["cert"].as_h.has_key?("notAfter").should be_true
    end
  end

  it "returns an Error result when the connection fails" do
    result = Nokizaru::Modules::SSLInfo.collect("127.0.0.1", HttpTestServer.closed_port)
    result.success?.should be_false
    result.error.should_not be_nil
  end

  it "stores into the typed run state under the sslinfo key" do
    TlsTestServer.with_server do |host, port|
      meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://#{host}", started_at: "t")
      run = Nokizaru::RunState.new(meta)
      run.modules.sslinfo = Nokizaru::Modules::SSLInfo.collect(host, port)
      run.modules.sslinfo.should_not be_nil
      JSON.parse(run.to_json)["modules"]["sslinfo"]["cert"]["serialNumber"].as_s.should eq("4096")
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

describe "Nokizaru::Modules::SSLInfo.present" do
  it "renders the certificate fields as rows and trees" do
    cert = Nokizaru::Modules::SSLInfo::CertInfo.new(
      protocol: "TLSv1.3", cipher: "TLS_AES_256_GCM_SHA384",
      subject: {"CN" => "example.com"}, issuer: {"O" => "Let's Encrypt", "CN" => "R3"},
      version: 3, serial_number: "0A1B", not_before: "Jan 01 00:00:00 2024 GMT",
      not_after: "Apr 01 00:00:00 2024 GMT", subject_alt_name: ["example.com", "www.example.com"])
    text = present_capture { Nokizaru::Modules::SSLInfo.present(Nokizaru::Modules::SSLInfo::Result.ok(cert)) }
    text.should contain("protocol")
    text.should contain("TLSv1.3")
    text.should contain("subject")
    text.should contain("example.com")
    text.should contain("subjectAltName")
    text.should contain("www.example.com")
    text.should contain("serialNumber")
  end

  it "renders a failure as an exception line" do
    text = present_capture { Nokizaru::Modules::SSLInfo.present(Nokizaru::Modules::SSLInfo::Result.failure("connection refused")) }
    text.should contain("connection refused")
  end
end
