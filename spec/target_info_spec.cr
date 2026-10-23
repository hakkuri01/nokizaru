require "./spec_helper"
require "../src/nokizaru/target_info"

private alias TargetInfo = Nokizaru::TargetInfo
private alias Options = Nokizaru::CLI::Options

private STUB = ->(_host : String) { "93.184.216.34".as(String?) }

private def options(target : String? = "https://www.example.com") : Options
  opts = Options.new
  opts.target = target
  opts
end

describe Nokizaru::TargetInfo do
  it "resolves a hostname target with settings defaults" do
    info = TargetInfo.resolve(options, resolve_ip: STUB)
    info.target.should eq("https://www.example.com")
    info.protocol.should eq("https")
    info.hostname.should eq("www.example.com")
    info.netloc.should eq("www.example.com")
    info.ip.should eq("93.184.216.34")
    info.type_ip?.should be_false
    info.private_ip?.should be_false
    info.ip_resolution_error.should be_nil
    info.notice.should be_nil
    info.domain.should eq("example")
    info.suffix.should eq("com")
    info.timeout.should eq(30.0)
    info.dns_servers.should eq("8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1")
    info.ssl_port.should eq(443)
    info.pscan_threads.should eq(50)
    info.pscan_ports.should be_nil
    info.dir_threads.should eq(50)
    info.wordlist.should eq("medium")
    info.extensions.should eq("")
    info.allow_redirects?.should be_false
    info.verify_ssl?.should be_false
    info.request_headers.empty?.should be_true
  end

  it "treats an IP literal target as resolved without DNS" do
    info = TargetInfo.resolve(options("http://127.0.0.1:8080"), resolve_ip: STUB)
    info.ip.should eq("127.0.0.1")
    info.type_ip?.should be_true
    info.private_ip?.should be_true
    info.netloc.should eq("127.0.0.1:8080")
    info.domain.should eq("")
    info.suffix.should eq("")
  end

  it "carries runtime options and parsed headers" do
    opts = options
    opts.timeout = 5.0
    opts.dir_threads = 10
    opts.port_threads = 20
    opts.ssl_port = 8443
    opts.wordlist = "large"
    opts.extensions = "php,txt"
    opts.redirects = true
    opts.verify_ssl = true
    opts.ports = "1-1000"
    opts.dns_servers = "1.1.1.1"
    opts.request_headers << "Cookie: secret"
    info = TargetInfo.resolve(opts, resolve_ip: STUB)
    info.timeout.should eq(5.0)
    info.dir_threads.should eq(10)
    info.pscan_threads.should eq(20)
    info.ssl_port.should eq(8443)
    info.wordlist.should eq("large")
    info.extensions.should eq("php,txt")
    info.allow_redirects?.should be_true
    info.verify_ssl?.should be_true
    info.pscan_ports.should eq("1-1000")
    info.dns_servers.should eq("1.1.1.1")
    info.request_headers["Cookie"].should eq("secret")
  end

  it "computes a notice for an unusual scheme and port" do
    TargetInfo.resolve(options("http://example.com:443"), resolve_ip: STUB).notice.should eq("Using http with port 443")
  end

  it "surfaces an unresolvable host without aborting" do
    info = TargetInfo.resolve(options("https://nope.invalid"), resolve_ip: ->(_h : String) { nil.as(String?) })
    info.ip.should be_nil
    info.ip_resolution_error.should_not be_nil
  end

  it "raises on fatal input" do
    expect_raises(TargetInfo::Error) { TargetInfo.resolve(options(nil), resolve_ip: STUB) }
    expect_raises(TargetInfo::Error) { TargetInfo.resolve(options("example.com"), resolve_ip: STUB) }
    expect_raises(TargetInfo::Error) { TargetInfo.resolve(options("https://user:pass@example.com"), resolve_ip: STUB) }
    opts = options
    opts.timeout = 0.0
    expect_raises(TargetInfo::Error) { TargetInfo.resolve(opts, resolve_ip: STUB) }
  end
end
