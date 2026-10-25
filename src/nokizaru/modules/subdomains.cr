require "json"
require "../subdom/providers"
require "../subdom/enumerator"
require "../http/pool"
require "../keystore"
require "../progress_reporter"
require "../ui"

module Nokizaru
  module Modules
    # Subdomain enumeration across 15 sources (Nokizaru::Modules::Subdomains),
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

      # Ruby job order, also the provider health order; quarantined adapters stay out
      PROVIDERS = [
        Subdom::AnubisDB.new, Subdom::CertSpotter.new, Subdom::HackerTarget.new,
        Subdom::UrlScan.new, Subdom::AlienVault.new, Subdom::BeVigil.new,
        Subdom::FacebookCT.new, Subdom::VirusTotal.new, Subdom::Shodan.new, Subdom::BinaryEdge.new,
        Subdom::ZoomEye.new, Subdom::Netlas.new, Subdom::Hunter.new, Subdom::Chaos.new, Subdom::Censys.new,
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

      def collect(host : String, timeout : Float64, pool : Http::Pool = Http::Pool.new, providers : Array(Subdom::Provider) = PROVIDERS, progress : ProgressReporter = ProgressReporter::NULL) : Result
        keys = resolve_keys(providers)
        names, outcomes = Subdom::Enumerator.new(providers).run(host, pool, keys, timeout, progress)
        Result.new(names, build_health(outcomes))
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
