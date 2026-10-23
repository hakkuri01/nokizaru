require "../spec_helper"
require "../../src/nokizaru/dirrec/fields"

describe Nokizaru::DirRec::Fields do
  it "extracts and normalizes the title" do
    Nokizaru::DirRec::Fields.extract_title("<html><title> Hello  World </title></html>").should eq("hello world")
    Nokizaru::DirRec::Fields.extract_title("<html></html>").should be_nil
  end

  it "normalizes content type and pattern path" do
    Nokizaru::DirRec::Fields.normalize_content_type("text/html; charset=utf-8").should eq("text/html")
    Nokizaru::DirRec::Fields.normalize_pattern_path("/a/").should eq("/a")
    Nokizaru::DirRec::Fields.normalize_pattern_path("").should eq("/")
  end

  it "fingerprints stably, collapsing volatile digits" do
    Nokizaru::DirRec::Fields.body_fingerprint("").should be_nil
    fp1 = Nokizaru::DirRec::Fields.body_fingerprint("<p>same page 12345</p>", "http://x.com/a")
    fp2 = Nokizaru::DirRec::Fields.body_fingerprint("<p>same page 67890</p>", "http://x.com/b")
    fp1.should eq(fp2)
  end

  it "classifies redirect patterns and statuses" do
    Nokizaru::DirRec::Fields.redirect_pattern("http://x.com/a", "http://x.com/a").should eq("same_path:http:x.com")
    Nokizaru::DirRec::Fields.redirect_pattern("http://x.com/a", "/login").should eq("auth_entry:http:x.com")
    Nokizaru::DirRec::Fields.generic_redirect_pattern?("same_path:http:x.com").should be_true
    Nokizaru::DirRec::Fields.redirect_status?(302).should be_true
    Nokizaru::DirRec::Fields.redirect_status?(200).should be_false
  end

  it "resolves and normalizes a Location against the request URL" do
    Nokizaru::DirRec::Fields.normalized_location_from_request("http://x.com/a", "/login").should eq("x.com/login")
    Nokizaru::DirRec::Fields.normalized_location_from_request("http://x.com/a", "").should be_nil
  end
end
