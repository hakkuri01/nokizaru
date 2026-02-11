# frozen_string_literal: true

require 'json'
require 'socket'
require_relative '../paths'
require_relative '../log'

module Nokizaru
  module Modules
    module WhoisLookup
      module_function

      # Run this module and store normalized results in the run context
      def call(domain, tld, ctx)
        result = {}
        begin
          db_json = JSON.parse(File.read(Paths.whois_servers_file))
        rescue Errno::ENOENT
          UI.line(:error, "Error : Missing whois server database file...⟦ #{Paths.whois_servers_file} ⟧")
          UI.line(:plus, 'Reinstall the gem/repo so data/whois_servers.json is present')
          Log.write('[whois] Missing whois_servers.json')
          ctx.run['modules']['whois'] = { 'Error' => 'Missing whois server DB (whois_servers.json)' }
          return
        end

        UI.module_header('Whois Lookup :')

        begin
          whois_sv = db_json.fetch(tld)
          query = tld.to_s.empty? ? domain.to_s : "#{domain}.#{tld}"
          cache_key = ctx.cache&.key_for(['whois', query, whois_sv])
          raw = ctx.cache_fetch(cache_key || "whois:#{query}", ttl_s: 86_400) do
            raw_whois(query, whois_sv)
          end
          print_whois(raw)
          result['whois'] = raw
        rescue KeyError
          UI.line(:error, 'Error : This domain suffix is not supported')
          result['Error'] = 'This domain suffix is not supported.'
          Log.write('[whois] Exception = This domain suffix is not supported.')
        rescue StandardError => e
          UI.line(:error, "Error : #{e}")
          result['Error'] = e.to_s
          Log.write("[whois] Exception = #{e}")
        end

        ctx.run['modules']['whois'] = result

        Log.write('[whois] Completed')
      end

      # Execute a low level whois query with bounded reads and timeout protection
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

      # Print whois text as aligned key/value rows when possible
      def print_whois(raw)
        pairs = []
        misc = []

        raw.to_s.each_line do |line|
          clean = line.strip
          next if clean.empty?

          if clean.include?(':')
            key, value = clean.split(':', 2)
            pairs << [key.strip, value.to_s.strip]
          else
            misc << clean
          end
        end

        UI.rows(:info, pairs) if pairs.any?
        misc.each { |line| UI.line(:info, line) }
      end
    end
  end
end
