# frozen_string_literal: true

require 'socket'
require 'openssl'
require_relative '../log'

module Nokizaru
  module Modules
    module SSLInfo
      module_function

      # Run this module and store normalized results in the run context
      def call(hostname, ssl_port, ctx)
        result = {}
        presence = false
        UI.module_header('SSL Certificate Information :')

        begin
          Socket.tcp(hostname, ssl_port, connect_timeout: 5) { |_s| }
          presence = true
        rescue StandardError
          presence = false
          UI.line(:error, 'SSL is not Present on Target URL...Skipping...')
          result['Error'] = 'SSL is not Present on Target URL'
          Log.write('[sslinfo] SSL is not Present on Target URL...Skipping...')
        end

        if presence
          begin
            tcp_socket = Socket.tcp(hostname, ssl_port, connect_timeout: 5)
            ssl_ctx = OpenSSL::SSL::SSLContext.new
            ssl_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
            ssl = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_ctx)
            ssl.hostname = hostname if ssl.respond_to?(:hostname=)
            ssl.sync_close = true
            ssl.connect

            cert = ssl.peer_cert

            subject_dict = x509_name_to_hash(cert.subject)
            issuer_dict = x509_name_to_hash(cert.issuer)

            not_before = cert.not_before.getutc.strftime('%b %d %H:%M:%S %Y GMT')
            not_after = cert.not_after.getutc.strftime('%b %d %H:%M:%S %Y GMT')

            cert_dict = {
              'protocol' => ssl.ssl_version,
              'cipher' => ssl.cipher,
              'subject' => subject_dict,
              'issuer' => issuer_dict,
              'version' => cert.version,
              'serialNumber' => cert.serial,
              'notBefore' => not_before,
              'notAfter' => not_after
            }

            san = extract_san(cert)
            cert_dict['subjectAltName'] = san if san && !san.empty?

            result['cert'] = cert_dict
            process_cert(cert_dict, result)
          rescue StandardError => e
            UI.line(:error, "Exception : #{e}")
            result['Error'] = e.to_s
            Log.write("[sslinfo] Exception = #{e}")
          ensure
            begin
              ssl&.close
            rescue StandardError
              nil
            end
          end
        end

        ctx.run['modules']['sslinfo'] = result

        Log.write('[sslinfo] Completed')
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

      # Normalize certificate metadata for module output and exports
      def process_cert(info, result)
        scalar_pairs = info.filter_map { |key, val| [key, val] unless val.is_a?(Hash) || val.is_a?(Array) }
        scalar_width = scalar_pairs.map { |(key, _)| key.to_s.length }.max.to_i

        info.each do |key, val|
          case val
          when Hash
            UI.tree_header(key)
            entries = val.map { |sub_key, sub_val| [sub_key, sub_val] }
            UI.tree_rows(entries)
            entries.each { |sub_key, sub_val| result["#{key}-#{sub_key}"] = sub_val }
          when Array
            UI.tree_header(key)
            entries = val.each_with_index.map { |sub_val, idx| [idx, sub_val] }
            UI.tree_rows(entries)
            entries.each { |idx, sub_val| result["#{key}-#{idx}"] = sub_val }
          else
            UI.row(:info, key, val, label_width: scalar_width)
            result[key] = val
          end
        end
      end
    end
  end
end
