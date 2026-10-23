require "../spec_helper"
require "../../src/nokizaru/tui/profile"

describe Nokizaru::Tui::Profile do
  it "carries the HUD run summary fields" do
    profile = Nokizaru::Tui::Profile.new(
      target: "https://example.com",
      ip: "93.184.216.34",
      modules: "full",
      switches: "-T 5",
      modules_enabled: ["headers", "dns"],
    )
    profile.target.should eq("https://example.com")
    profile.ip.should eq("93.184.216.34")
    profile.modules.should eq("full")
    profile.switches.should eq("-T 5")
    profile.modules_enabled.should eq(["headers", "dns"])
    profile.notice.should be_nil
  end

  it "carries an optional notice" do
    profile = Nokizaru::Tui::Profile.new(
      target: "http://x", ip: "1.2.3.4", modules: "headers", switches: "none",
      modules_enabled: ["headers"], notice: "Using http with port 8080",
    )
    profile.notice.should eq("Using http with port 8080")
  end
end
