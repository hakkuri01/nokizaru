require "../spec_helper"
require "../../src/nokizaru/psl/list"

# A small synthetic list exercises the algorithm (wildcard + exception)
# deterministically, independent of real-list drift.
private def synthetic : Nokizaru::PSL::List
  Nokizaru::PSL::List.new("// comment\ncom\nco.uk\nuk\n*.ck\n!www.ck\n")
end

describe Nokizaru::PSL::List do
  describe "#public_suffix" do
    it "picks the rule with the most labels" do
      synthetic.public_suffix("www.example.co.uk").should eq("co.uk")
    end

    it "returns a single-label suffix" do
      synthetic.public_suffix("example.com").should eq("com")
    end

    it "falls back to the rightmost label when no rule matches" do
      synthetic.public_suffix("host.unknownnope").should eq("unknownnope")
    end

    it "returns nil for an empty host" do
      synthetic.public_suffix("").should be_nil
    end
  end

  describe "#registrable_domain" do
    it "is the public suffix plus one label" do
      synthetic.registrable_domain("www.example.co.uk").should eq("example.co.uk")
      synthetic.registrable_domain("a.b.example.com").should eq("example.com")
    end

    it "is nil when the host is itself a public suffix" do
      synthetic.registrable_domain("co.uk").should be_nil
      synthetic.registrable_domain("com").should be_nil
    end

    it "applies a wildcard rule so the wildcard label is part of the suffix" do
      # *.ck means foo.ck is itself a public suffix; bar.foo.ck is registrable.
      synthetic.registrable_domain("foo.ck").should be_nil
      synthetic.registrable_domain("bar.foo.ck").should eq("bar.foo.ck")
    end

    it "applies an exception rule so the excepted label becomes registrable" do
      # !www.ck excepts www.ck from *.ck, making ck the suffix and www.ck registrable.
      synthetic.registrable_domain("www.ck").should eq("www.ck")
    end

    it "normalizes case and a trailing dot" do
      synthetic.registrable_domain("WWW.Example.CO.UK.").should eq("example.co.uk")
    end
  end

  describe "the embedded list" do
    it "parses a full list of rules" do
      Nokizaru::PSL::List.default.rule_count.should be > 9_000
    end

    it "answers real canaries" do
      list = Nokizaru::PSL::List.default
      list.public_suffix("www.example.co.uk").should eq("co.uk")
      list.registrable_domain("a.b.example.com").should eq("example.com")
    end
  end
end
