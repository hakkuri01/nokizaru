require "socket"
require "openssl"
require "json"
require "../http/x509_ext"
require "../ui"

module Nokizaru
  module Modules
    # SSL/TLS certificate inspection. Opens a TLS connection to the target, reads
    # the peer certificate, and records protocol, cipher, subject, issuer,
    # version, serial, validity, and SAN. Field names and shape match the Ruby
    # tool's JSON (the parity contract): the module stores a cert payload on
    # success or an Error string on failure. Certificate fields the stdlib does
    # not expose come from Http::X509Ext. Ports modules/sslinfo.rb.
    module SSLInfo
      extend self

      CONNECT_TIMEOUT = 5.0
      LABEL_WIDTH     = "serialNumber".size

      # The certificate payload, serialized under "cert". Key order and names
      # match the Ruby cert dict; camelCase keys are mapped explicitly.
      struct CertInfo
        include JSON::Serializable

        getter protocol : String?
        getter cipher : String?
        getter subject : Hash(String, String)
        getter issuer : Hash(String, String)
        getter version : Int32
        @[JSON::Field(key: "serialNumber")]
        getter serial_number : String
        @[JSON::Field(key: "notBefore")]
        getter not_before : String
        @[JSON::Field(key: "notAfter")]
        getter not_after : String
        @[JSON::Field(key: "subjectAltName")]
        getter subject_alt_name : Array(String)?

        def initialize(
          @protocol : String?,
          @cipher : String?,
          @subject : Hash(String, String),
          @issuer : Hash(String, String),
          @version : Int32,
          @serial_number : String,
          @not_before : String,
          @not_after : String,
          @subject_alt_name : Array(String)?,
        )
        end
      end

      struct Result
        include JSON::Serializable

        getter cert : CertInfo?

        @[JSON::Field(key: "Error")]
        getter error : String?

        def initialize(@cert : CertInfo? = nil, @error : String? = nil)
        end

        def self.ok(cert : CertInfo) : Result
          new(cert: cert)
        end

        def self.failure(message : String) : Result
          new(error: message)
        end

        def success? : Bool
          !@cert.nil?
        end
      end

      # Renders the certificate for the classic output and the dashboard capture,
      # matching the Ruby field order (scalars as rows, subject/issuer/SAN as
      # trees). The header bar is dropped in TUI mode (the tab names the module).
      def present(result : Result) : Nil
        UI.module_header("SSL Certificate Information")
        cert = result.cert
        unless cert
          UI.line(:error, "Exception : #{result.error}")
          return
        end

        UI.row(:info, "protocol", cert.protocol, label_width: LABEL_WIDTH)
        UI.row(:info, "cipher", cert.cipher, label_width: LABEL_WIDTH)
        present_tree("subject", cert.subject)
        present_tree("issuer", cert.issuer)
        UI.row(:info, "version", cert.version.to_s, label_width: LABEL_WIDTH)
        UI.row(:info, "serialNumber", cert.serial_number, label_width: LABEL_WIDTH)
        UI.row(:info, "notBefore", cert.not_before, label_width: LABEL_WIDTH)
        UI.row(:info, "notAfter", cert.not_after, label_width: LABEL_WIDTH)
        present_san(cert.subject_alt_name)
      end

      private def present_tree(label : String, values : Hash(String, String)) : Nil
        UI.tree_header(label)
        UI.tree_rows(values.map { |key, value| {key, value.as(String?)} })
      end

      private def present_san(san : Array(String)?) : Nil
        return if san.nil? || san.empty?

        UI.tree_header("subjectAltName")
        UI.tree_rows(san.map_with_index { |value, index| {index.to_s, value.as(String?)} })
      end

      def collect(hostname : String, ssl_port : Int32, verify_ssl : Bool = false) : Result
        socket = connect(hostname, ssl_port, verify_ssl)
        begin
          cert = socket.peer_certificate
          return Result.failure("no peer certificate") if cert.nil?

          Result.ok(build_cert_info(socket, cert))
        ensure
          socket.close rescue nil
        end
      rescue error
        Result.failure(error.message || error.class.name)
      end

      private def connect(hostname : String, ssl_port : Int32, verify_ssl : Bool) : OpenSSL::SSL::Socket::Client
        tcp = TCPSocket.new(hostname, ssl_port, connect_timeout: CONNECT_TIMEOUT)
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless verify_ssl
        OpenSSL::SSL::Socket::Client.new(tcp, context: context, hostname: hostname, sync_close: true)
      end

      private def build_cert_info(socket : OpenSSL::SSL::Socket::Client, cert : OpenSSL::X509::Certificate) : CertInfo
        san = Http::X509Ext.san(cert)
        CertInfo.new(
          protocol: socket.tls_version,
          cipher: socket.cipher,
          subject: name_hash(cert.subject.to_a),
          issuer: name_hash(Http::X509Ext.issuer(cert)),
          version: Http::X509Ext.version(cert),
          serial_number: Http::X509Ext.serial(cert),
          not_before: format_time(Http::X509Ext.not_before(cert)),
          not_after: format_time(Http::X509Ext.not_after(cert)),
          subject_alt_name: san.empty? ? nil : san,
        )
      end

      private def name_hash(entries : Array({String, String})) : Hash(String, String)
        entries.each_with_object({} of String => String) do |(oid, value), hash|
          hash[oid] = value
        end
      end

      private def format_time(time : Time?) : String
        return "" if time.nil?

        time.to_s("%b %d %H:%M:%S %Y GMT")
      end
    end
  end
end
