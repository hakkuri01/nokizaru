require "../spec_helper"
require "../../src/nokizaru/dirrec/path_helpers"

describe Nokizaru::DirRec::PathHelpers do
  it "joins a base and path, normalizing the slash" do
    Nokizaru::DirRec::PathHelpers.join_url("http://x.com/", "admin").should eq("http://x.com/admin")
    Nokizaru::DirRec::PathHelpers.join_url("http://x.com", "/a/b").should eq("http://x.com/a/b")
  end

  it "percent-encodes path words per byte without plus-encoding spaces" do
    Nokizaru::DirRec::PathHelpers.encode_path_word("a b/c").should eq("a%20b/c")
    Nokizaru::DirRec::PathHelpers.encode_path_word("wp-admin.php").should eq("wp-admin.php")
  end
end
