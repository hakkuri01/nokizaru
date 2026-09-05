# frozen_string_literal: true

require 'whois'
require_relative '../log'

module Nokizaru
  module Modules
    module WhoisLookup
      module_function

      def call(domain, tld, ctx)
        UI.module_header('Whois Lookup')
        ctx.progress&.update(:whois, stage: 'querying')
        result = whois_result(domain, tld)
        ctx.progress&.update(:whois, stage: 'complete', detail: "#{result.fetch('whois', '').lines.count} lines")
      rescue ::Whois::ServerError
        result = unsupported_suffix_result
      rescue StandardError => e
        result = exception_result(e)
      ensure
        write_whois_result(ctx, result) if result
      end

      def whois_result(domain, tld)
        query = build_query(domain, tld)
        raw = normalize_whois_text(raw_whois(query))
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

      def build_query(domain, tld)
        tld.to_s.empty? ? domain.to_s : "#{domain}.#{tld}"
      end

      def raw_whois(query)
        ::Whois::Client.new(timeout: 10, referral: false).lookup(query).to_s.split('>>>', 2).first
      end

      def normalize_whois_text(raw)
        text = raw.to_s.dup
        return '' if text.empty?

        return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

        text.force_encoding(Encoding::BINARY)
            .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
      rescue EncodingError
        text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
      end

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
          misc << normalize_misc_line(clean)
        end
      end

      def normalize_misc_line(line)
        line.sub(/\ANo match for "([^"]+)"\.\z/i) do
          "No match for #{Regexp.last_match(1).downcase}"
        end
      end
    end
  end
end
