require "../spec_helper"
require "../support/tls_test_server"
require "../../src/nokizaru/http/x509_ext"

describe Nokizaru::Http::X509Ext do
  it "reads issuer, version, serial, validity, and SAN from a live certificate" do
    TlsTestServer.with_server do |host, port|
      TlsTestServer.with_client(host, port) do |ssl|
        cert = ssl.peer_certificate.not_nil!

        Nokizaru::Http::X509Ext.version(cert).should eq(2)
        Nokizaru::Http::X509Ext.serial(cert).should eq("4096")
        Nokizaru::Http::X509Ext.issuer(cert).should contain({"CN", "nokizaru.test"})
        Nokizaru::Http::X509Ext.san(cert).should eq(["nokizaru.test", "www.nokizaru.test"])

        before = Nokizaru::Http::X509Ext.not_before(cert).not_nil!
        after = Nokizaru::Http::X509Ext.not_after(cert).not_nil!
        before.should be <= Time.utc
        after.should be > before
      end
    end
  end
end
