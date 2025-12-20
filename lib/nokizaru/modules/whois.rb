# frozen_string_literal: true

require 'json'
require 'socket'
require_relative 'export'
require_relative '../paths'
require_relative '../log'

module Nokizaru
  module Modules
    module WhoisLookup
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      def call(domain, tld, output, data)
        result = {}
        db_json = JSON.parse(File.read(Paths.whois_servers_file))

        puts("\n#{Y}[!] Whois Lookup : #{W}\n\n")

        begin
          whois_sv = db_json.fetch(tld)
          query = tld.to_s.empty? ? domain.to_s : "#{domain}.#{tld}"
          raw = raw_whois(query, whois_sv)
          puts(raw)
          result['whois'] = raw
        rescue KeyError
          puts("#{R}[-] Error : #{C}This domain suffix is not supported.#{W}")
          result['Error'] = 'This domain suffix is not supported.'
          Log.write('[whois] Exception = This domain suffix is not supported.')
        rescue StandardError => exc
          puts("#{R}[-] Error : #{C}#{exc}#{W}")
          result['Error'] = exc.to_s
          Log.write("[whois] Exception = #{exc}")
        end

        result['exported'] = false

        if output
          fname = File.join(output[:directory], "whois.#{output[:format]}")
          output[:file] = fname
          data['module-whois'] = result
          Export.call(output, data)
        end

        Log.write('[whois] Completed')
      end

      def raw_whois(query, server)
        resp = +''
        Socket.tcp(server, 43, connect_timeout: 5) do |sock|
          sock.write("#{query}\r\n")
          while (chunk = sock.read(4096))
            resp << chunk
          end
        end
        # Keep as raw text
        resp.split('>>>', 2).first
      end
    end
  end
end
