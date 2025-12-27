# frozen_string_literal: true

require 'dnsruby'
require_relative '../log'

module Nokizaru
  module Modules
    module DNSEnumeration
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      DNS_RECORDS = %w[
        A AAAA AFSDB APL CAA CDNSKEY CDS CERT CNAME CSYNC DHCID DLV DNAME DNSKEY DS
        EUI48 EUI64 HINFO HIP HTTPS IPSECKEY KEY KX LOC MX NAPTR NS NSEC NSEC3
        NSEC3PARAM OPENPGPKEY PTR RP RRSIG SIG SMIMEA SOA SRV SSHFP SVCB TA TKEY
        TLSA TSIG TXT URI ZONEMD
      ].freeze

      def format_rdata(rdata)
        # Dnsruby returns simple rdata as strings/objects, but DNSSEC-ish records often return arrays with binary strings.
        case rdata
        when Array
          rdata.map { |v| format_rdata(v) }.join(' ')
        when String
          # If string contains non-printable bytes, encode it.
          if rdata.bytes.any? { |b| b < 32 || b > 126 }
            require 'base64'
            Base64.strict_encode64(rdata)
          else
            rdata
          end
        else
          rdata.to_s
        end
      end

      def call(domain, dns_servers, ctx)
        result = { 'records' => {} }
        puts("\n#{Y}[!] Starting DNS Enumeration...#{W}\n\n")

        full_ans = []

        # Hard cap keeps full scans smooth even on flaky resolvers.
        per_query_timeout = 2
        nameservers = (dns_servers.split(',').map(&:strip) if dns_servers && !dns_servers.to_s.empty?)

        # Quick NXDOMAIN check (avoid spawning a pool for a dead domain).
        begin
          check = Dnsruby::Resolver.new
          check.do_caching = false
          check.query_timeout = per_query_timeout
          check.retry_times = 1 if check.respond_to?(:retry_times=)
          check.nameserver = nameservers if nameservers
          check.query(domain, 'A')
        rescue Dnsruby::NXDomain => e
          Log.write("[dns] Exception = #{e}")
          puts("#{R}[-] #{C}DNS Records Not Found!#{W}")
          result['error'] = 'DNS Records Not Found'
          ctx.run['modules']['dns'] = result
          return
        rescue StandardError
          # ignore; proceed to best-effort enumeration.
        end

        q = Queue.new
        DNS_RECORDS.each { |rr| q << rr }

        out = Queue.new
        worker_n = 12

        workers = Array.new(worker_n) do
          Thread.new do
            resolver = Dnsruby::Resolver.new
            resolver.do_caching = false
            resolver.query_timeout = per_query_timeout
            resolver.retry_times = 1 if resolver.respond_to?(:retry_times=)
            resolver.nameserver = nameservers if nameservers

            loop do
              rr_type = begin
                q.pop(true)
              rescue StandardError
                nil
              end
              break unless rr_type

              begin
                resp = resolver.query(domain, rr_type)
                resp.answer.each do |rr|
                  out << [rr_type, format_rdata(rr.rdata)]
                end
              rescue Dnsruby::ResolvError, Dnsruby::NXRRSet
                # NODATA is common; treat as empty.
              rescue Dnsruby::NXDomain
                # Domain disappeared mid-run; stop this worker.
                break
              rescue StandardError => e
                Log.write("[dns] Exception = #{e}")
              end
            end
          end
        end

        workers.each(&:join)

        # Drain results and preserve deterministic output order.
        temp = []
        begin
          loop { temp << out.pop(true) }
        rescue ThreadError
          # queue empty
        end

        order_idx = DNS_RECORDS.each_with_index.to_h
        temp.sort_by! { |(t, _)| order_idx[t] || 9_999 }
        temp.each do |rr_type, rr_val|
          (result['records'][rr_type] ||= []) << rr_val
        end

        result['records'].each do |rr_type, rr_vals|
          Array(rr_vals).each do |rr_val|
            puts("#{C}#{rr_type}\t: #{W}#{rr_val}")
            full_ans << "#{rr_type} : #{rr_val}"
          end
        end

        # DMARC (separate query; not part of the RR loop)
        dmarc_target = "_dmarc.#{domain}"
        begin
          dmarc_resolver = Dnsruby::Resolver.new
          dmarc_resolver.do_caching = false
          dmarc_resolver.query_timeout = per_query_timeout
          dmarc_resolver.retry_times = 1 if dmarc_resolver.respond_to?(:retry_times=)
          dmarc_resolver.nameserver = nameservers if nameservers

          resp = dmarc_resolver.query(dmarc_target, 'TXT')
          resp.answer.each do |rr|
            puts("#{C}DMARC \t: #{W}#{rr.rdata}")
            (result['records']['DMARC'] ||= []) << rr.rdata.to_s
          end
        rescue Dnsruby::NXDomain => e
          Log.write("[dns.dmarc] Exception = #{e}")
          puts("\n#{R}[-] #{C}DMARC Record Not Found!#{W}")
          result['records']['DMARC'] ||= []
        rescue Dnsruby::ResolvError => e
          Log.write("[dns.dmarc] Exception = #{e}")
        rescue StandardError => e
          Log.write("[dns.dmarc] Exception = #{e}")
        end

        ctx.run['modules']['dns'] = result

        # artifacts
        txt = Array(result.dig('records', 'TXT'))
        ctx.add_artifact('dns_txt', txt)

        Log.write('[dns] Completed')
      end
    end
  end
end
