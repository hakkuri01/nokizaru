# frozen_string_literal: true

require 'whois'
require 'json'
require 'uri'
require_relative '../http_client'
require_relative '../log'

module Nokizaru
  module Modules
    module WhoisLookup
      module_function

      RDAP_ORIGIN = 'https://rdap.org'
      NOT_FOUND = /^\s*(?:[%#]\s*)?(?:no\s+match\s+for|not\s+found\b|no\s+data\s+found\b|
                    no\s+entries\s+found\b|no\s+object\s+found\b|domain\s+.{0,255}\s+not\s+found\b|
                    the\s+queried\s+object\s+does\s+not\s+exist\b|no\s+match!!\s*$)/ix
      UNSUPPORTED = /^\s*(?:[%#]\s*)?(?:no\s+whois\s+server|
                      whois\s+(?:service\s+)?(?:is\s+)?not\s+(?:available|supported))/ix
      RDAP_REFERRAL = /(?:whois.{0,40}(?:retired|discontinued|unsupported)|(?:use|refer\w*|transition\w*).{0,40}rdap)/i
      DOMAIN_FIELDS = [
        /^\s*Domain(?: Name)?[.]*:[ \t]*(\S+)[ \t]*\r?$/i,
        /^\s*(?:a\.\s*)?\[Domain Name\][ \t]+(\S+)[ \t]*\r?$/i,
        /^\s*Domain name:[ \t]*\r?\n[ \t]+(\S+)[ \t]*$/i
      ].freeze

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
        finish_whois(query, raw, classify_whois(raw, query))
      rescue ::Whois::ConnectionError => e
        finish_whois(query, '', :transport_error, e.to_s)
      rescue ::Whois::ServerError
        finish_whois(query, '', :unsupported, 'This domain suffix is not supported.')
      rescue StandardError => e
        finish_whois(query, '', :unusable, e.to_s)
      end

      def classify_whois(raw, query = nil)
        text = raw.to_s.strip
        return :retired if text.match?(RDAP_REFERRAL)
        return :usable if matching_domain_field?(text, query)
        return :not_found if text.match?(NOT_FOUND)
        return :unsupported if text.match?(UNSUPPORTED)
        return :no_data if text.empty?

        :unusable
      end

      def matching_domain_field?(text, query)
        expected = normalize_domain(query)
        return false if expected.empty?

        DOMAIN_FIELDS.any? do |field|
          text.scan(field).flatten.any? { |domain| normalize_domain(domain) == expected }
        end
      end

      def finish_whois(query, raw, classification, legacy_error = nil)
        print_whois(raw) unless raw.empty?
        result = { 'whois' => raw }
        result['Error'] = legacy_error if legacy_error

        case classification
        when :usable
          result.merge('status' => 'registered', 'source' => 'whois')
        when :not_found
          result.merge('status' => 'not_found', 'source' => 'whois')
        else
          rdap_result(query, result, "whois_#{classification}")
        end
      end

      def rdap_result(query, result, whois_reason)
        response = fetch_rdap(query)
        status = Nokizaru::HTTPClient.status_code(response)
        if status == 404
          reason = rdap_no_service?(Nokizaru::HTTPClient.response_body(response)) && 'rdap_no_service'
          return degraded_result(result, whois_reason, reason) if reason

          return result.merge('status' => 'not_found', 'source' => 'rdap', 'reasons' => [whois_reason])
        end

        reason = rdap_failure_reason(response, status)
        return degraded_result(result, whois_reason, reason) if reason

        summary = parse_rdap(Nokizaru::HTTPClient.response_body(response), query)
        return degraded_result(result, whois_reason, summary) if summary.is_a?(String)

        print_rdap(summary)
        result.except('Error', 'error').merge(summary).merge(
          'status' => 'registered', 'source' => 'rdap', 'reasons' => [whois_reason]
        )
      rescue StandardError
        degraded_result(result, whois_reason, 'rdap_transport_error')
      end

      def fetch_rdap(query)
        url = "#{RDAP_ORIGIN}/domain/#{URI.encode_www_form_component(query)}"
        client = Nokizaru::HTTPClient.for_host(
          RDAP_ORIGIN, timeout_s: 10, headers: { 'Accept' => 'application/rdap+json' }
        )
        client.get(url)
      end

      def rdap_failure_reason(response, status)
        return 'rdap_transport_error' if response.nil? || Nokizaru::HTTPClient.error_response?(response)
        return nil if status == 200
        return 'rdap_rate_limited' if status == 429
        return 'rdap_server_error' if status >= 500

        'rdap_http_error'
      end

      def rdap_no_service?(body)
        data = JSON.parse(body)
        data.is_a?(Hash) && data['title'].to_s.casecmp?('No RDAP service is available for this resource')
      rescue JSON::ParserError, TypeError
        false
      end

      def parse_rdap(body, query)
        data = JSON.parse(body)
        return 'rdap_malformed_response' unless data.is_a?(Hash) && data['objectClassName'].to_s.casecmp?('domain')

        expected = normalize_domain(query)
        names = [data['ldhName'], data['unicodeName']].compact.map { |name| normalize_domain(name) }
        return 'rdap_domain_mismatch' unless names.include?(expected)

        rdap_summary(data, expected)
      rescue JSON::ParserError, TypeError
        'rdap_malformed_response'
      end

      def rdap_summary(data, domain)
        {
          'domain' => domain,
          'handle' => data['handle'].to_s,
          'registration_status' => Array(data['status']).map(&:to_s),
          'events' => Array(data['events']).filter_map { |event| normalize_event(event) },
          'nameservers' => Array(data['nameservers']).filter_map { |server| normalize_nameserver(server) }.uniq
        }
      end

      def normalize_domain(domain)
        domain.to_s.strip.downcase.delete_suffix('.')
      end

      def normalize_event(event)
        return unless event.is_a?(Hash)

        action = event['eventAction'].to_s
        date = event['eventDate'].to_s
        { 'action' => action, 'date' => date } unless action.empty? || date.empty?
      end

      def normalize_nameserver(server)
        return unless server.is_a?(Hash)

        name = server['ldhName'] || server['unicodeName']
        normalized = normalize_domain(name)
        normalized unless normalized.empty?
      end

      def degraded_result(result, whois_reason, rdap_reason)
        message = 'No usable registration data returned'
        result.merge(
          'status' => 'degraded',
          'source' => 'rdap',
          'Error' => result['Error'] || message,
          'error' => message,
          'reasons' => [whois_reason, rdap_reason]
        )
      end

      def print_rdap(summary)
        UI.rows(:info, [
                  ['Domain', summary['domain']],
                  ['Handle', summary['handle']],
                  ['Status', summary['registration_status'].join(', ')],
                  ['Events', summary['events'].map { |event| "#{event['action']}: #{event['date']}" }.join(', ')],
                  ['Nameservers', summary['nameservers'].join(', ')]
                ])
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
