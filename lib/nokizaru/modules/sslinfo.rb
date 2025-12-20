# frozen_string_literal: true

require 'socket'
require 'openssl'
require_relative 'export'
require_relative '../log'

module Nokizaru
  module Modules
    module SSLInfo
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      def call(hostname, ssl_port, output, data)
        result = {}
        presence = false
        puts("\n#{Y}[!] SSL Certificate Information : #{W}\n\n")

        begin
          Socket.tcp(hostname, ssl_port, connect_timeout: 5) { |_s| }
          presence = true
        rescue StandardError
          presence = false
          puts("#{R}[-] #{C}SSL is not Present on Target URL...Skipping...#{W}")
          result['Error'] = 'SSL is not Present on Target URL'
          Log.write('[sslinfo] SSL is not Present on Target URL...Skipping...')
        end

        if presence
          begin
            tcp_socket = Socket.tcp(hostname, ssl_port, connect_timeout: 5)
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
            ssl = OpenSSL::SSL::SSLSocket.new(tcp_socket, ctx)
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

            process_cert(cert_dict, result)
          rescue StandardError => e
            puts("#{R}[-] #{C}Exception : #{W}#{e}")
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

        result['exported'] = false

        if output
          fname = File.join(output[:directory], "ssl.#{output[:format]}")
          output[:file] = fname
          data['module-SSL Certificate Information'] = result
          Export.call(output, data)
        end

        Log.write('[sslinfo] Completed')
      end

      def x509_name_to_hash(name)
        h = {}
        name.to_a.each do |(oid, val, _type)|
          h[oid] = val
        end
        h
      end

      def extract_san(cert)
        ext = cert.extensions.find { |e| e.oid == 'subjectAltName' }
        return [] unless ext

        ext.value.split(',').map(&:strip).filter_map do |entry|
          if entry.start_with?('DNS:')
            entry.sub('DNS:', '').strip
          end
        end
      end

      def process_cert(info, result)
        info.each do |key, val|
          case val
          when Hash
            puts("#{G}[+] #{C}#{key}#{W}")
            val.each do |sub_key, sub_val|
              puts("\t#{G}└╴#{C}#{sub_key}: #{W}#{sub_val}")
              result["#{key}-#{sub_key}"] = sub_val
            end
          when Array
            puts("#{G}[+] #{C}#{key}#{W}")
            val.each_with_index do |sub_val, idx|
              puts("\t#{G}└╴#{C}#{idx}: #{W}#{sub_val}")
              result["#{key}-#{idx}"] = sub_val
            end
          else
            puts("#{G}[+] #{C}#{key} : #{W}#{val}")
            result[key] = val
          end
        end
      end
    end
  end
end
