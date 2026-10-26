require "json"
require "../subdom/providers"
require "../subdom/enumerator"
require "../http/pool"
require "../keystore"
require "../progress_reporter"
require "./sslinfo"
require "./dns"
require "../ui"

module Nokizaru
  module Modules
    # Subdomain enumeration across a curated 17-source set (Nokizaru::Modules::Subdomains),
    # driving the Nokizaru::Subdom engine. Ports modules/subdom.rb. The JSON
    # result matches the Ruby run hash (parity): the sorted unique subdomains
    # plus a provider_health summary. The event-capture/replay machinery that
    # ordered concurrent provider UI output in the Ruby tool is a rendering
    # concern and is replaced by each provider returning a typed Outcome; the UI
    # rendering wires up with the runner.
    module Subdomains
      extend self

      # One provider's health line; absent fields are omitted (parity).
      struct ProviderHealth
        include JSON::Serializable

        getter name : String
        getter status : String
        getter reason : String?
        getter elapsed_s : Float64?
        getter result_count : Int32?

        def initialize(@name : String, @status : String, @reason : String? = nil, @elapsed_s : Float64? = nil, @result_count : Int32? = nil)
        end
      end

      struct Health
        include JSON::Serializable

        getter providers : Array(ProviderHealth)
        getter counts : Hash(String, Int32)

        def initialize(@providers : Array(ProviderHealth), @counts : Hash(String, Int32))
        end
      end

      struct Result
        include JSON::Serializable

        getter subdomains : Array(String)
        getter provider_health : Health

        def initialize(@subdomains : Array(String), @provider_health : Health)
        end
      end

      # Job order, also the provider health order: a trusted keyless core (CT,
      # passive DNS, URL-derived) then key-enriched sources that self-skip without
      # a key. Curated, not exhaustive: the mature providers, not every source.
      PROVIDERS = [
        Subdom::AnubisDB.new, Subdom::CertSpotter.new, Subdom::CrtSh.new, Subdom::Digitorus.new,
        Subdom::HackerTarget.new, Subdom::RapidDNS.new, Subdom::UrlScan.new, Subdom::WaybackArchive.new,
        Subdom::AlienVault.new, Subdom::BeVigil.new, Subdom::VirusTotal.new, Subdom::Shodan.new,
        Subdom::Chaos.new, Subdom::Censys.new, Subdom::SecurityTrails.new, Subdom::Github.new, Subdom::Gitlab.new,
      ] of Subdom::Provider

      TOTAL_LABEL = "Total unique subdomains found"

      # Renders the first 20 subdomains as a tree, a truncation note, and the
      # total; the provider health is stored but not printed (as the Ruby tool
      # did). Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Sub-Domain Enumeration")
        found = result.subdomains
        width = [TOTAL_LABEL.size, "Results truncated".size].max
        unless found.empty?
          UI.tree_header("Results")
          UI.tree_rows(found.first(20).map { |subdomain| {"Subdomain", subdomain.as(String?)} })
          UI.row(:info, "Results truncated", "#{found.size - 20} more", label_width: width) if found.size > 20
        end
        UI.blank_line
        UI.row(:info, TOTAL_LABEL, found.size.to_s, label_width: width)
      end

      def collect(host : String, timeout : Float64, pool : Http::Pool = Http::Pool.new, providers : Array(Subdom::Provider) = PROVIDERS, progress : ProgressReporter = ProgressReporter::NULL, sslinfo : Modules::SSLInfo::Result? = nil, dns : Modules::DnsEnumeration::Result? = nil) : Result
        keys = resolve_keys(providers)
        seeds = certificate_seeds(sslinfo, host)
        seeds.concat(dns_seeds(dns, host))
        seeds.uniq!
        names, outcomes = Subdom::Enumerator.new(providers).run(host, pool, keys, timeout, progress, seeds)
        # Sources that opt out of health reporting (Wayback) still contribute
        # names but are left out of the summary so their server-side flakiness
        # does not misrepresent the module's health.
        silent = providers.reject(&.report_health?).map(&.name)
        reported = outcomes.reject { |outcome| silent.includes?(outcome.name) }
        Result.new(names, build_health(reported))
      end

      # Subdomains harvested from the DNS zone: NS, CNAME, and MX hostnames are
      # real infrastructure subdomains that certificate transparency and the
      # passive providers often miss. MX values carry a preference prefix, so the
      # hostname is the last token. Only strict subdomains of the target host are
      # kept (the enumerator re-applies scope). dns runs before this module.
      private def dns_seeds(dns : Modules::DnsEnumeration::Result?, host : String) : Array(String)
        return [] of String if dns.nil?

        records = dns.records
        names = [] of String
        names.concat(records["NS"]? || [] of String)
        names.concat(records["CNAME"]? || [] of String)
        names.concat((records["MX"]? || [] of String).compact_map(&.split.last?))
        suffix = ".#{host}"
        names.compact_map do |raw|
          cleaned = raw.strip.rchop('.')
          cleaned if cleaned.ends_with?(suffix)
        end.uniq!
      end

      # Subdomains harvested from the TLS certificate's SAN list (certificate
      # transparency is the passive source subfinder-class tools lean on). Only
      # strict subdomains of the target host are kept; a wildcard SAN is reduced to
      # its base, and the apex and out-of-scope names are dropped (the enumerator
      # re-applies scope, this keeps the seed set tight). sslinfo runs before this
      # module, so its result is already on the run state.
      private def certificate_seeds(sslinfo : Modules::SSLInfo::Result?, host : String) : Array(String)
        cert = sslinfo.try(&.cert)
        return [] of String if cert.nil?

        suffix = ".#{host}"
        names = cert.subject_alt_name || [] of String
        names.compact_map do |name|
          cleaned = name.lchop("*.").strip.rchop('.')
          cleaned if cleaned.ends_with?(suffix)
        end.uniq!
      end

      # Resolves every provider's keys once (env first, then the key store), so
      # the providers stay decoupled from the store. A provider whose keys are
      # absent is skipped inside its run.
      private def resolve_keys(providers : Array(Subdom::Provider)) : Hash(String, String)
        available = {} of String => String
        providers.each do |provider|
          provider.key_names.each do |(name, env)|
            next if available.has_key?(name)

            value = KeyStore.fetch(name, env)
            available[name] = value if value && !value.empty?
          end
        end
        available
      end

      private def build_health(outcomes : Array(Subdom::Outcome)) : Health
        providers = outcomes.map { |outcome| health_entry(outcome) }
        counts = {"total" => outcomes.size}
        outcomes.each { |outcome| counts[outcome.status] = (counts[outcome.status]? || 0) + 1 }
        Health.new(providers, counts)
      end

      private def health_entry(outcome : Subdom::Outcome) : ProviderHealth
        reason = outcome.reason
        reason = nil if reason && reason.empty?
        ProviderHealth.new(outcome.name, outcome.status, reason, outcome.elapsed_s, outcome.result_count)
      end
    end
  end
end
