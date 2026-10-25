require "socket"
require "openssl"
require "file_utils"

# A loopback-only TLS fixture for the sslinfo and x509_ext specs. It generates a
# throwaway self-signed certificate once (via the openssl CLI, no network) with a
# known serial and SAN, serves TLS on 127.0.0.1 on an ephemeral port, and never
# touches a routable interface. The certificate is a test fixture, not a secret:
# it is generated into a temp dir and removed at exit, never committed.
module TlsTestServer
  extend self

  @@material : {String, String}? = nil

  def material : {String, String}
    @@material ||= generate
  end

  private def generate : {String, String}
    dir = File.tempname("nokizaru-tls")
    Dir.mkdir_p(dir)
    at_exit { FileUtils.rm_rf(dir) }
    cert = File.join(dir, "cert.pem")
    key = File.join(dir, "key.pem")
    status = Process.run("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
      "-days", "2", "-nodes", "-set_serial", "4096",
      "-subj", "/CN=nokizaru.test/O=NokizaruTest/C=US",
      "-addext", "subjectAltName=DNS:nokizaru.test,DNS:www.nokizaru.test",
    ], output: Process::Redirect::Close, error: Process::Redirect::Close)
    raise "openssl CLI unavailable for the TLS test fixture" unless status.success?

    {cert, key}
  end

  def with_server(context = OpenSSL::SSL::Context::Server.new, &block : (String, Int32) ->) : Nil
    cert, key = material
    context.certificate_chain = cert
    context.private_key = key
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    spawn do
      while connection = server.accept?
        handshake(connection, context)
      end
    end
    begin
      block.call("127.0.0.1", port)
    ensure
      server.close
    end
  end

  def with_client(host : String, port : Int32, &block : OpenSSL::SSL::Socket::Client ->) : Nil
    tcp = TCPSocket.new(host, port)
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: context, hostname: "nokizaru.test", sync_close: true)
    begin
      block.call(ssl)
    ensure
      ssl.close rescue nil
    end
  end

  private def handshake(connection : TCPSocket, context : OpenSSL::SSL::Context::Server) : Nil
    OpenSSL::SSL::Socket::Server.new(connection, context).close
  rescue
    nil
  ensure
    connection.close rescue nil
  end
end
