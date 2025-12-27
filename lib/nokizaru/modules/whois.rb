# frozen_string_literal: true

require 'json'
require 'socket'
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

      def call(domain, tld, ctx)
        result = {}
        begin
          db_json = JSON.parse(File.read(Paths.whois_servers_file))
        rescue Errno::ENOENT
          puts("#{R}[-] Error : #{C}Missing whois server database file: #{W}#{Paths.whois_servers_file}")
          puts("#{G}[+] #{C}Reinstall the gem/repo so #{W}data/whois_servers.json#{C} is present.")
          Log.write('[whois] Missing whois_servers.json')
          ctx.run['modules']['whois'] = { 'Error' => 'Missing whois server DB (whois_servers.json)' }
          return
        end

        puts("\n#{Y}[!] Whois Lookup : #{W}\n\n")

        begin
          whois_sv = db_json.fetch(tld)
          query = tld.to_s.empty? ? domain.to_s : "#{domain}.#{tld}"
          cache_key = ctx.cache&.key_for(['whois', query, whois_sv])
          raw = ctx.cache_fetch(cache_key || "whois:#{query}", ttl_s: 86_400) do
            raw_whois(query, whois_sv)
          end
          puts(raw)
          result['whois'] = raw
        rescue KeyError
          puts("#{R}[-] Error : #{C}This domain suffix is not supported.#{W}")
          result['Error'] = 'This domain suffix is not supported.'
          Log.write('[whois] Exception = This domain suffix is not supported.')
        rescue StandardError => e
          puts("#{R}[-] Error : #{C}#{e}#{W}")
          result['Error'] = e.to_s
          Log.write("[whois] Exception = #{e}")
        end

        ctx.run['modules']['whois'] = result

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
