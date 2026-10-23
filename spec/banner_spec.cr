require "./spec_helper"
require "../src/nokizaru/banner"

describe Nokizaru::Banner do
  it "embeds the figlet wordmark art" do
    Nokizaru::Banner::TEXT.should contain("▐ ▄")
    Nokizaru::Banner::TEXT.lines.size.should be > 10
  end
end
