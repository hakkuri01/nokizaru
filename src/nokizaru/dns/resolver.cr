require "socket"

module Nokizaru
  module Dns
    # Resolves a hostname to an IP for connection setup, preferring IPv4 as the
    # Ruby resolver did. stdlib getaddrinfo is concurrency-safe in 1.21; the
    # lookup runs in a fiber and a select enforces the deadline, returning
    # nil if the lookup outruns it. Ports resolve_hostname_ip; record
    # enumeration (the dns module, 38 types) is its own wire client.
    class Resolver
      DEFAULT_TIMEOUT = 5.0

      def resolve(hostname : String, timeout_s : Float64 = DEFAULT_TIMEOUT) : String?
        return hostname if ip_literal?(hostname)

        answer = Channel(String?).new(1)
        spawn { answer.send(lookup(hostname)) }
        return answer.receive if timeout_s <= 0

        select
        when ip = answer.receive
          ip
        when timeout(timeout_s.seconds)
          nil
        end
      end

      def ip_literal?(hostname : String) : Bool
        Socket::IPAddress.new(hostname, 0)
        true
      rescue Socket::Error
        false
      end

      # One A/AAAA lookup, preferring an IPv4 address and falling back to the
      # first of any family. Complexity: O(records) over the bounded result.
      private def lookup(hostname : String) : String?
        records = Socket::Addrinfo.resolve(hostname, 80, type: Socket::Type::STREAM)
        chosen = records.find(&.ip_address.family.inet?) || records.first?
        chosen.try(&.ip_address.address)
      rescue Socket::Addrinfo::Error
        nil
      end
    end
  end
end
