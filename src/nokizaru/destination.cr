require "socket"
require "./dns/resolver"

module Nokizaru
  # Where an outbound request is allowed to land. Scope decides which names a
  # scan may follow; this decides which addresses those names may resolve to,
  # because a target controls its own DNS and can point an in-scope name at the
  # operator's own network. One home for the check: the HTTP pool and the WHOIS
  # referral both ask here.
  #
  # The policy follows the target the operator chose. A scan aimed at a public
  # host refuses internal destinations, and a scan aimed at an internal one (an
  # intranet name, a lab address) allows them, so pointing the tool at 10.0.0.5
  # still works. Katana offers the same distinction as an opt-in `-exclude
  # private-ips` filter; here it is the default, because Nokizaru's scope grows
  # from server data (crawled links, redirect targets, archive seeds) and those
  # requests carry the operator's -H credentials.
  module Destination
    extend self

    # A bounded DNS hostname: the only shape a referral or a crawled host may
    # take, so nothing carrying whitespace, controls, or credentials is dialed.
    HOSTNAME = /\A[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,251}[a-zA-Z0-9])?\z/

    # Addresses a scan must not reach from a public target: loopback, private
    # (RFC 1918 and unique-local), link-local (which carries the cloud metadata
    # service at 169.254.169.254), and unspecified (0.0.0.0, which some stacks
    # connect to locally). Multicast is left out because a TCP connect to one has
    # nowhere to land.
    def internal_address?(address : Socket::IPAddress) : Bool
      address.loopback? || address.private? || address.link_local? || address.unspecified?
    end

    def internal_address?(value : String) : Bool
      address = parse(value)
      !address.nil? && internal_address?(address)
    end

    # The policy a scan runs under. `allow_internal` comes from the operator's own
    # target; a name that does not resolve is refused rather than dialed.
    def policy(allow_internal : Bool, resolve : Proc(String, String?) = ->(host : String) { Dns::Resolver.new.resolve(host) }) : Proc(String, Bool)
      ->(host : String) { allow_internal || public_host?(host, resolve) }
    end

    # The default for a destination that should always be a public service (the
    # WHOIS referral chain), independent of the scan target.
    def public_policy : Proc(String, Bool)
      policy(allow_internal: false)
    end

    # True when the host is a well-formed name or literal that does not land on
    # an internal address. One resolution per host; callers cache the answer.
    def public_host?(host : String, resolve : Proc(String, String?)) : Bool
      value = host.strip.downcase
      return false if value.empty?

      if literal = parse(value)
        return !internal_address?(literal)
      end
      return false unless value.matches?(HOSTNAME)

      resolved = resolve.call(value)
      return false if resolved.nil?

      address = parse(resolved)
      !address.nil? && !internal_address?(address)
    end

    private def parse(value : String) : Socket::IPAddress?
      Socket::IPAddress.new(value, 0)
    rescue Socket::Error
      nil
    end
  end
end
