require "../spec_helper"
require "../../src/nokizaru/findings/dns_rules"

private def dns_result(records : Hash(String, Array(String))) : Nokizaru::Modules::DnsEnumeration::Result
  Nokizaru::Modules::DnsEnumeration::Result.new(records)
end

describe Nokizaru::Findings::DNSRules do
  it "returns nothing when the dns module did not run" do
    Nokizaru::Findings::DNSRules.call(nil).should be_empty
  end

  it "is silent when both SPF and DMARC are present" do
    result = dns_result({"TXT" => ["v=spf1 include:_spf.example.com -all"], "DMARC" => ["v=DMARC1; p=reject"]})
    Nokizaru::Findings::DNSRules.call(result).should be_empty
  end

  it "flags both when neither SPF nor DMARC is present" do
    result = dns_result({"A" => ["1.2.3.4"], "DMARC" => [] of String})
    ids = Nokizaru::Findings::DNSRules.call(result).map(&.id)
    ids.should eq(["dns.missing_spf", "dns.missing_dmarc"])
  end

  it "flags only the missing one when SPF is present but DMARC is not" do
    result = dns_result({"TXT" => ["v=spf1 -all"]})
    ids = Nokizaru::Findings::DNSRules.call(result).map(&.id)
    ids.should eq(["dns.missing_dmarc"])
  end
end
