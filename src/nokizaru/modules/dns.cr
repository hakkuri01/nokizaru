require "json"
require "../dns/client"
require "../dns/record_type"
require "../dns/presentation"
require "../ui"

module Nokizaru
  module Modules
    # DNS record enumeration across the common and security-relevant types
    # (RecordType::NAMES, the Ruby DNS_RECORDS list). Named DnsEnumeration to
    # avoid colliding with the wire-client namespace Nokizaru::Dns. Ports
    # modules/dns.rb: check the domain exists, enumerate every type, add DMARC
    # as a TXT query at _dmarc.<domain>, and shape the result as the Ruby JSON
    # (the parity contract): a `records` map of type => presented values, plus
    # an `error` when the name does not resolve. The UI rendering, the
    # add_artifact("dns_txt", ...) call, and the nameserver source wiring are
    # assembled with the runner.
    module DnsEnumeration
      extend self

      # NXDOMAIN rcode: the one outcome that means the name itself is absent.
      NXDOMAIN = 3_u8
      # A last-resort resolver pair when the system config names none. Any DNS
      # query reaches some resolver; the user overrides with -ns.
      DEFAULT_NAMESERVERS = %w[8.8.8.8 1.1.1.1]

      # The per-module result. `records` keeps insertion order, and the module
      # fills it in RecordType::NAMES order with DMARC last, so the JSON matches
      # the Ruby sorted output without a sort step. `error` is omitted unless the
      # domain did not resolve.
      struct Result
        include JSON::Serializable

        getter records : Hash(String, Array(String))
        getter error : String?

        def initialize(@records : Hash(String, Array(String)), @error : String? = nil)
        end
      end

      # Renders the enumerated records for the classic output and the dashboard
      # capture: one row per record value, labeled by its type, in enumeration
      # order. The header bar is dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("DNS Enumeration")
        if result.error
          UI.line(:error, "DNS Records Not Found!")
          return
        end

        pairs = [] of Tuple(String, String?)
        result.records.each do |record_type, values|
          values.each { |value| pairs << {record_type, value.as(String?)} }
        end
        UI.rows(:info, pairs) unless pairs.empty?
      end

      # Enumerates every record type for `domain` across `nameservers`.
      # Complexity: O(T) queries for the T = 38 fixed types (plus one existence
      # probe and one DMARC query), each a bounded round trip tried against the
      # nameservers in order, each response parsed and presented in a bounded
      # pass. ponytail: the Ruby tool spread these over a 12-thread pool; this
      # port runs them serially for simplicity (a resolver answers an empty type
      # fast, so only an unreachable resolver pays the per-query timeout). The
      # upgrade path is bounded fibers over a Channel, deferred to the
      # benchmarking pass.
      def collect(domain : String, nameservers : Array(String), client : Dns::Client = Dns::Client.new) : Result
        records = {} of String => Array(String)
        return Result.new(records, "DNS Records Not Found") unless domain_exists?(domain, nameservers, client)

        Dns::RecordType::NAMES.each do |name|
          code = Dns::RecordType.code(name)
          next if code.nil?

          values = query_values(domain, code, nameservers, client)
          records[name] = values unless values.empty?
        end
        records["DMARC"] = dmarc(domain, nameservers, client)
        Result.new(records)
      end

      # Reads the system resolver list (the `nameserver` lines of resolv.conf),
      # falling back to the public pair when none are configured. The path is a
      # parameter so the parsing is testable without the live file. O(lines).
      def system_nameservers(path : String = "/etc/resolv.conf") : Array(String)
        servers = [] of String
        if File.exists?(path)
          File.each_line(path) do |line|
            fields = line.strip.split
            servers << fields[1] if fields.size >= 2 && fields[0] == "nameserver"
          end
        end
        servers.empty? ? DEFAULT_NAMESERVERS.dup : servers
      end

      # The Ruby gate: a name that answers NXDOMAIN to an A query does not
      # exist; any other outcome (an answer, another rcode, or a resolver that
      # never replied) is treated as "exists, enumerate it".
      private def domain_exists?(domain : String, nameservers : Array(String), client : Dns::Client) : Bool
        code = Dns::RecordType.code("A")
        return true if code.nil?

        message = resolve(domain, code, nameservers, client)
        return true if message.nil?

        message.rcode != NXDOMAIN
      end

      private def dmarc(domain : String, nameservers : Array(String), client : Dns::Client) : Array(String)
        code = Dns::RecordType.code("TXT")
        return [] of String if code.nil?

        query_values("_dmarc.#{domain}", code, nameservers, client)
      end

      # The presented values of every answer that matches the queried type.
      # Unlike the Ruby tool, which labeled every answer RR with the queried
      # type (so a CNAME in an MX answer printed under MX), this keeps only the
      # matching type; the CNAME still appears under its own CNAME query, so no
      # information is lost and the mislabeling is dropped.
      private def query_values(domain : String, code : UInt16, nameservers : Array(String), client : Dns::Client) : Array(String)
        message = resolve(domain, code, nameservers, client)
        return [] of String if message.nil?

        message.answers.compact_map do |record|
          Dns::Presentation.format(record) if record.type == code
        end
      end

      private def resolve(domain : String, code : UInt16, nameservers : Array(String), client : Dns::Client) : Dns::Message?
        nameservers.each do |nameserver|
          message = client.query(domain, code, nameserver)
          return message unless message.nil?
        end
        nil
      end
    end
  end
end
