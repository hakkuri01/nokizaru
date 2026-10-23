require "./spec_helper"
require "digest/sha256"
require "../src/nokizaru/psl"

# The PSL integrity pin (C9): the embedded list must match the known-good hash
# and must still be the structured Mozilla list. A refresh updates both the file
# and Nokizaru::PSL::SHA256 together, so any unreviewed drift fails here.
describe Nokizaru::PSL do
  it "embeds exactly the pinned Public Suffix List" do
    Digest::SHA256.hexdigest(Nokizaru::PSL::DATA).should eq(Nokizaru::PSL::SHA256)
  end

  it "carries the ICANN and PRIVATE sections intact" do
    Nokizaru::PSL::DATA.should contain("// ===BEGIN ICANN DOMAINS===")
    Nokizaru::PSL::DATA.should contain("// ===BEGIN PRIVATE DOMAINS===")
    Nokizaru::PSL::DATA.should contain("// ===END PRIVATE DOMAINS===")
  end
end
