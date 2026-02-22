# frozen_string_literal: true

require 'json'
require 'socket'
require_relative '../paths'
require_relative '../log'

module Nokizaru
  module Modules
    # Nokizaru::Modules::WhoisLookup implementation
    module WhoisLookup
      module_function

      # Run this module and store normalized results in the run context
      def call(domain, tld, ctx)
        db_json = load_whois_database
        return missing_whois_database!(ctx) unless db_json

        UI.module_header('Whois Lookup :')
        result = whois_result(domain, tld, db_json, ctx)
      rescue KeyError
        result = unsupported_suffix_result
      rescue StandardError => e
        result = exception_result(e)
      ensure
        write_whois_result(ctx, result) if result
      end

      def whois_result(domain, tld, db_json, ctx)
        query = build_query(domain, tld)
        whois_server = db_json.fetch(tld)
        raw = cached_whois(ctx, query, whois_server)
        print_whois(raw)
        { 'whois' => raw }
      end

      def unsupported_suffix_result
        UI.line(:error, 'Error : This domain suffix is not supported')
        Log.write('[whois] Exception = This domain suffix is not supported.')
        { 'Error' => 'This domain suffix is not supported.' }
      end

      def exception_result(error)
        UI.line(:error, "Error : #{error}")
        Log.write("[whois] Exception = #{error}")
        { 'Error' => error.to_s }
      end

      def write_whois_result(ctx, result)
        ctx.run['modules']['whois'] = result
        Log.write('[whois] Completed')
      end

      def load_whois_database
        JSON.parse(File.read(Paths.whois_servers_file))
      rescue Errno::ENOENT
        nil
      end

      def missing_whois_database!(ctx)
        UI.line(:error, "Error : Missing whois server database file...⟦ #{Paths.whois_servers_file} ⟧")
        UI.line(:plus, 'Reinstall the gem/repo so data/whois_servers.json is present')
        Log.write('[whois] Missing whois_servers.json')
        ctx.run['modules']['whois'] = { 'Error' => 'Missing whois server DB (whois_servers.json)' }
      end

      def build_query(domain, tld)
        tld.to_s.empty? ? domain.to_s : "#{domain}.#{tld}"
      end

      def cached_whois(ctx, query, server)
        cache_key = ctx.cache&.key_for(['whois', query, server])
        ctx.cache_fetch(cache_key || "whois:#{query}", ttl_s: 86_400) { raw_whois(query, server) }
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
        pairs, misc = parse_whois_lines(raw)
        UI.rows(:info, pairs) if pairs.any?
        misc.each { |line| UI.line(:info, line) }
      end

      def parse_whois_lines(raw)
        pairs = []
        misc = []
        raw.to_s.each_line { |line| append_whois_line(pairs, misc, line) }
        [pairs, misc]
      end

      def append_whois_line(pairs, misc, line)
        clean = line.strip
        return if clean.empty?

        if clean.include?(':')
          key, value = clean.split(':', 2)
          pairs << [key.strip, value.to_s.strip]
        else
          misc << clean
        end
      end
    end
  end
end
