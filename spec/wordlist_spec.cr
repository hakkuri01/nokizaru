require "./spec_helper"
require "../src/nokizaru/wordlist"

describe Nokizaru::Wordlist do
  it "loads an embedded curated list for a size name, case insensitively" do
    medium = Nokizaru::Wordlist.load("medium")
    medium.size.should be > 1_000
    Nokizaru::Wordlist.load("MEDIUM").should eq(medium)
    Nokizaru::Wordlist.load("small").size.should be < medium.size
    Nokizaru::Wordlist.load("large").size.should be > medium.size
  end

  it "loads a custom path, dropping blanks and duplicates in first-seen order" do
    path = File.tempname("nok-wordlist", ".txt")
    File.write(path, "admin\n\nconfig\nadmin\n  backup  \n")
    begin
      Nokizaru::Wordlist.load(path).should eq(["admin", "config", "backup"])
    ensure
      File.delete(path)
    end
  end

  it "raises for a path it cannot read instead of returning no words" do
    # An empty list would run the scan on its seeds alone and look like a
    # complete result, which is how a mistyped -w used to pass unnoticed.
    expect_raises(File::NotFoundError) do
      Nokizaru::Wordlist.load(File.tempname("nok-absent", ".txt"))
    end
  end
end
