# frozen_string_literal: true

require 'base64'
require 'dnsruby'

module Nokizaru
  module Modules
    module DNSEnumeration
      # Resolver and formatting helpers for DNS enumeration
      module ResolverHelpers
        module_function

        def format_rdata(rdata)
          case rdata
          when Array
            rdata.map { |value| format_rdata(value) }.join(' ')
          when String
            binary_string?(rdata) ? Base64.strict_encode64(rdata) : rdata
          else
            rdata.to_s
          end
        end

        def binary_string?(value)
          value.bytes.any? { |byte| byte < 32 || byte > 126 }
        end

        def build_resolver(per_query_timeout, nameservers)
          resolver = Dnsruby::Resolver.new
          resolver.do_caching = false
          resolver.query_timeout = per_query_timeout
          resolver.retry_times = 1 if resolver.respond_to?(:retry_times=)
          resolver.nameserver = nameservers if nameservers
          resolver
        end

        def domain_exists?(domain, per_query_timeout, nameservers)
          resolver = build_resolver(per_query_timeout, nameservers)
          resolver.query(domain, 'A')
          true
        rescue Dnsruby::NXDomain
          false
        rescue StandardError
          true
        end

        def enumerate_records(domain, nameservers, per_query_timeout)
          queue = Queue.new
          DNSEnumeration::DNS_RECORDS.each { |record_type| queue << record_type }
          out = Queue.new
          workers = build_workers(domain, nameservers, per_query_timeout, queue, out)
          workers.each(&:join)
          drain_queue(out)
        end

        def build_workers(domain, nameservers, per_query_timeout, queue, out)
          Array.new(12) do
            Thread.new do
              resolver = build_resolver(per_query_timeout, nameservers)
              process_record_queue(resolver, domain, queue, out)
            end
          end
        end

        def process_record_queue(resolver, domain, queue, out)
          loop do
            record_type = pop_record_type(queue)
            break unless record_type

            state = collect_record_response(resolver, domain, record_type, out)
            break if state == :stop
          end
        end

        def pop_record_type(queue)
          queue.pop(true)
        rescue StandardError
          nil
        end

        def collect_record_response(resolver, domain, record_type, out)
          response = resolver.query(domain, record_type)
          response.answer.each { |resource_record| out << [record_type, format_rdata(resource_record.rdata)] }
        rescue Dnsruby::ResolvError, Dnsruby::NXRRSet
          nil
        rescue Dnsruby::NXDomain
          :stop
        rescue StandardError => e
          Log.write("[dns] Exception = #{e}")
          nil
        end

        def drain_queue(queue)
          entries = []
          loop { entries << queue.pop(true) }
        rescue ThreadError
          entries
        end

        def dmarc_records(domain, nameservers, per_query_timeout)
          resolver = build_resolver(per_query_timeout, nameservers)
          response = resolver.query("_dmarc.#{domain}", 'TXT')
          response.answer.map { |resource_record| format_rdata(resource_record.rdata) }
        rescue Dnsruby::NXDomain, Dnsruby::ResolvError, StandardError => e
          Log.write("[dns.dmarc] Exception = #{e}")
          []
        end

        def sorted_record_pairs(entries)
          order_index = DNSEnumeration::DNS_RECORDS.each_with_index.to_h
          entries.sort_by { |(record_type, _)| order_index[record_type] || 9_999 }
        end
      end
    end
  end
end
