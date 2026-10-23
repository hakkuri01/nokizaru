require "../spec_helper"
require "../../src/nokizaru/subdom/enumerator"

describe Nokizaru::Subdom::ResultSet do
  it "keeps only in-scope, valid, deduplicated names, sorted" do
    set = Nokizaru::Subdom::ResultSet.new("example.com")
    set.add(["www.example.com", "example.com", "evil.net", " ftp.example.com ", "bad name.example.com", "www.example.com"])

    set.sorted.should eq(["example.com", "ftp.example.com", "www.example.com"])
  end

  it "drops a bare empty or whitespace entry" do
    set = Nokizaru::Subdom::ResultSet.new("example.com")
    set.add(["", "   ", "a.example.com"])
    set.sorted.should eq(["a.example.com"])
  end
end
