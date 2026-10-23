require "../spec_helper"
require "../../src/nokizaru/findings/port_rules"

private def scanned(port : Int32, name : String) : Nokizaru::Portscan::PortRecord
  Nokizaru::Portscan::PortRecord.build("1.2.3.4", Nokizaru::Portscan::OpenPort.new(port, name, 1.0))
end

private def result(records : Array(Nokizaru::Portscan::PortRecord)) : Nokizaru::Modules::PortScan::Result
  Nokizaru::Modules::PortScan::Result.new(records.map(&.label), records, records.size, "normal", "medium")
end

describe Nokizaru::Findings::PortRules do
  it "returns nothing when the portscan module did not run" do
    Nokizaru::Findings::PortRules.call(nil).should be_empty
  end

  it "flags a sensitive service port" do
    findings = Nokizaru::Findings::PortRules.call(result([scanned(6379, "Redis")]))

    findings.size.should eq(1)
    findings.first.id.should eq("ports.sensitive_open")
    findings.first.severity.should eq("medium")
    findings.first.evidence.not_nil!.should contain("6379 (Redis) [database]")
  end

  it "is silent when no risky ports are open" do
    Nokizaru::Findings::PortRules.call(result([scanned(80, "HTTP"), scanned(22, "SSH")])).should be_empty
  end

  it "skips a tarpit-downgraded risky port" do
    downgraded = scanned(6379, "Redis")
    downgraded.downgrade_tarpit!
    Nokizaru::Findings::PortRules.call(result([downgraded])).should be_empty
  end
end
