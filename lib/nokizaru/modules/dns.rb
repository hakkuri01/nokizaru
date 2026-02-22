# frozen_string_literal: true

require 'dnsruby'
require_relative '../log'
require_relative 'dns/resolver_helpers'

module Nokizaru
  module Modules
    # DNS record enumeration across common and security-relevant types
    module DNSEnumeration
      module_function

      DNS_RECORDS = %w[
        A AAAA AFSDB APL CAA CDNSKEY CDS CERT CNAME CSYNC DHCID DLV DNAME DNSKEY DS
        EUI48 EUI64 HINFO HIP HTTPS IPSECKEY KEY KX LOC MX NAPTR NS NSEC NSEC3
        NSEC3PARAM OPENPGPKEY PTR RP RRSIG SIG SMIMEA SOA SRV SSHFP SVCB TA TKEY
        TLSA TSIG TXT URI ZONEMD
      ].freeze

      def call(domain, dns_servers, ctx)
        result = { 'records' => {} }
        UI.module_header('Starting DNS Enumeration...')
        state = build_dns_state(domain, dns_servers)
        return mark_domain_missing(result, ctx) unless domain_exists?(state)

        state[:record_pairs] =
          ResolverHelpers.enumerate_records(state[:domain], state[:nameservers], state[:per_query_timeout])
        complete_enumeration!(result, ctx, state)
      end

      def build_dns_state(domain, dns_servers)
        {
          domain: domain,
          nameservers: parse_nameservers(dns_servers),
          per_query_timeout: 2,
          record_pairs: []
        }
      end

      def domain_exists?(state)
        ResolverHelpers.domain_exists?(state[:domain], state[:per_query_timeout], state[:nameservers])
      end

      def complete_enumeration!(result, ctx, state)
        merge_record_pairs!(result, ResolverHelpers.sorted_record_pairs(state[:record_pairs]))
        merge_dmarc_records!(result, state[:domain], state[:nameservers], state[:per_query_timeout])
        print_records(result)
        persist_dns_result(ctx, result)
      end

      def parse_nameservers(dns_servers)
        return nil if dns_servers.nil? || dns_servers.to_s.empty?

        dns_servers.split(',').map(&:strip)
      end

      def mark_domain_missing(result, ctx)
        UI.line(:error, 'DNS Records Not Found!')
        result['error'] = 'DNS Records Not Found'
        ctx.run['modules']['dns'] = result
        nil
      end

      def merge_record_pairs!(result, record_pairs)
        record_pairs.each do |record_type, record_value|
          (result['records'][record_type] ||= []) << record_value
        end
      end

      def merge_dmarc_records!(result, domain, nameservers, per_query_timeout)
        dmarc = ResolverHelpers.dmarc_records(domain, nameservers, per_query_timeout)
        result['records']['DMARC'] = dmarc
      end

      def print_records(result)
        rows = display_rows(result)
        UI.rows(:info, rows) if rows.any?
      end

      def display_rows(result)
        result['records'].flat_map do |record_type, values|
          Array(values).map { |value| [record_type, value] }
        end
      end

      def persist_dns_result(ctx, result)
        ctx.run['modules']['dns'] = result
        ctx.add_artifact('dns_txt', Array(result.dig('records', 'TXT')))
        Log.write('[dns] Completed')
      end
    end
  end
end
