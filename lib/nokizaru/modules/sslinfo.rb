# frozen_string_literal: true

require 'socket'
require 'openssl'
require_relative '../log'
require_relative 'sslinfo/presenter'

module Nokizaru
  module Modules
    # Nokizaru::Modules::SSLInfo implementation
    module SSLInfo
      module_function

      # Run this module and store normalized results in the run context
      def call(hostname, ssl_port, ctx)
        result = {}
        UI.module_header('SSL Certificate Information :')

        if ssl_available?(hostname, ssl_port)
          collect_ssl_certificate(hostname, ssl_port, result)
        else
          mark_ssl_unavailable(result)
        end

        finalize_ssl_module(ctx, result)
      end

      def finalize_ssl_module(ctx, result)
        ctx.run['modules']['sslinfo'] = result
        Log.write('[sslinfo] Completed')
      end

      def ssl_available?(hostname, ssl_port)
        probe_socket = Socket.tcp(hostname, ssl_port, connect_timeout: 5)
        probe_socket.close
        true
      rescue StandardError
        false
      end

      def mark_ssl_unavailable(result)
        UI.line(:error, 'SSL is not Present on Target URL...Skipping...')
        result['Error'] = 'SSL is not Present on Target URL'
        Log.write('[sslinfo] SSL is not Present on Target URL...Skipping...')
      end

      def collect_ssl_certificate(hostname, ssl_port, result)
        ssl = open_ssl_socket(hostname, ssl_port)
        cert_dict = build_cert_payload(ssl)
        result['cert'] = cert_dict
        Presenter.process_cert(cert_dict, result)
      rescue StandardError => e
        UI.line(:error, "Exception : #{e}")
        result['Error'] = e.to_s
        Log.write("[sslinfo] Exception = #{e}")
      ensure
        ssl&.close
      end

      def open_ssl_socket(hostname, ssl_port)
        tcp_socket = Socket.tcp(hostname, ssl_port, connect_timeout: 5)
        ssl_ctx = OpenSSL::SSL::SSLContext.new
        ssl_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        ssl = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_ctx)
        ssl.hostname = hostname if ssl.respond_to?(:hostname=)
        ssl.sync_close = true
        ssl.connect
        ssl
      end

      def build_cert_payload(ssl)
        cert = ssl.peer_cert
        payload = base_cert_payload(ssl, cert)
        san = extract_san(cert)
        payload['subjectAltName'] = san if san && !san.empty?
        payload
      end

      def base_cert_payload(ssl, cert)
        identity = cert_identity_fields(cert)
        payload = {
          'protocol' => ssl.ssl_version,
          'cipher' => ssl.cipher,
          'subject' => identity[:subject],
          'issuer' => identity[:issuer],
          'version' => identity[:version],
          'serialNumber' => identity[:serial]
        }
        payload.merge(cert_validity_payload(cert))
      end

      def cert_identity_fields(cert)
        {
          subject: x509_name_to_hash(cert.subject),
          issuer: x509_name_to_hash(cert.issuer),
          version: cert.version,
          serial: cert.serial
        }
      end

      def cert_validity(cert)
        {
          not_before: cert.not_before.getutc.strftime('%b %d %H:%M:%S %Y GMT'),
          not_after: cert.not_after.getutc.strftime('%b %d %H:%M:%S %Y GMT')
        }
      end

      def cert_validity_payload(cert)
        validity = cert_validity(cert)
        { 'notBefore' => validity[:not_before], 'notAfter' => validity[:not_after] }
      end

      # Convert certificate name objects into a stable key value hash
      def x509_name_to_hash(name)
        h = {}
        name.to_a.each do |(oid, val, _type)|
          h[oid] = val
        end
        h
      end

      # Extract SAN entries used for host and wildcard visibility
      def extract_san(cert)
        ext = cert.extensions.find { |e| e.oid == 'subjectAltName' }
        return [] unless ext

        ext.value.split(',').map(&:strip).filter_map do |entry|
          entry.sub('DNS:', '').strip if entry.start_with?('DNS:')
        end
      end
    end
  end
end
