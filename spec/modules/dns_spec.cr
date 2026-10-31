require "../spec_helper"
require "../support/dns_test_server"
require "../../src/nokizaru/modules/dns"
require "../../src/nokizaru/run_state"

describe Nokizaru::Modules::DnsEnumeration do
  describe ".collect" do
    it "enumerates records in DNS_RECORDS order with DMARC last" do
      by_type = {
         1_u16 => [{1_u16, Bytes[93, 184, 216, 34]}],
         2_u16 => [{2_u16, DnsTestServer.encode_name("ns1.example.com")}, {2_u16, DnsTestServer.encode_name("ns2.example.com")}],
        16_u16 => [{16_u16, DnsTestServer.char_string("v=spf1 -all")}],
      }

      DnsTestServer.with_resolver(by_type) do |port|
        client = Nokizaru::Dns::Client.new(timeout_s: 1.0, port: port)
        result = Nokizaru::Modules::DnsEnumeration.collect("example.com", ["127.0.0.1"], client)

        result.error.should be_nil
        result.records["A"].should eq(["93.184.216.34"])
        result.records["NS"].should eq(["ns1.example.com", "ns2.example.com"])
        result.records["TXT"].should eq(["v=spf1 -all"])
        result.records["DMARC"].should eq(["v=spf1 -all"]) # the _dmarc TXT query
        result.records.has_key?("MX").should be_false      # an empty type is omitted
        result.records.keys.should eq(["A", "NS", "TXT", "DMARC"])
      end
    end

    it "reports the name as missing on NXDOMAIN without enumerating" do
      DnsTestServer.with_resolver({} of UInt16 => Array(DnsTestServer::Answer), nxdomain: true) do |port|
        client = Nokizaru::Dns::Client.new(timeout_s: 1.0, port: port)
        result = Nokizaru::Modules::DnsEnumeration.collect("nope.example.com", ["127.0.0.1"], client)

        result.error.should eq("DNS Records Not Found")
        result.records.empty?.should be_true
      end
    end

    it "serializes success to the Ruby JSON shape (records only)" do
      DnsTestServer.with_resolver({1_u16 => [{1_u16, Bytes[1, 2, 3, 4]}]}) do |port|
        client = Nokizaru::Dns::Client.new(timeout_s: 1.0, port: port)
        result = Nokizaru::Modules::DnsEnumeration.collect("example.com", ["127.0.0.1"], client)

        json = result.to_json
        json.should contain(%("A":["1.2.3.4"]))
        json.should_not contain("error")
      end
    end
  end

  describe ".domain_exists?" do
  end

  describe "run-state wiring" do
    it "stores the result on modules.dns under the \"dns\" key" do
      meta = Nokizaru::Meta.new(version: "1.0.0", target: "https://example.com", started_at: "2026-10-20T00:00:00Z")
      run = Nokizaru::RunState.new(meta)
      run.modules.dns = Nokizaru::Modules::DnsEnumeration::Result.new({"A" => ["1.2.3.4"]})

      run.modules.dns.should_not be_nil
      JSON.parse(run.to_json)["modules"]["dns"]["records"]["A"].as_a.map(&.as_s).should eq(["1.2.3.4"])
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

describe "Nokizaru::Modules::DnsEnumeration.present" do
  it "renders one row per record value, labeled by type" do
    result = Nokizaru::Modules::DnsEnumeration::Result.new(
      {"A" => ["93.184.216.34"], "MX" => ["10 mail.example.com"]})
    text = present_capture { Nokizaru::Modules::DnsEnumeration.present(result) }
    text.should contain("93.184.216.34")
    text.should contain("mail.example.com")
  end

  it "reports when no records were found" do
    result = Nokizaru::Modules::DnsEnumeration::Result.new({} of String => Array(String), "DNS Records Not Found")
    present_capture { Nokizaru::Modules::DnsEnumeration.present(result) }.should contain("DNS Records Not Found!")
  end
end
