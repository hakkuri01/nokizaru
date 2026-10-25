require "json"
require "./terminal_text"
require "./finding"
require "./module_outcome"
require "./modules/sslinfo"
require "./modules/headers"
require "./modules/arch"
require "./modules/dns"
require "./modules/whois"
require "./modules/portscan"
require "./modules/subdomains"
require "./modules/crawler"
require "./modules/wayback"
require "./modules/dirrec"

module Nokizaru
  # Run metadata. hostname and ip emit null when unresolved, as the Ruby tool did
  # (the key is always present); ended_at and elapsed_s are filled at finalize.
  class Meta
    include JSON::Serializable

    property version : String
    property target : String

    @[JSON::Field(emit_null: true)]
    property hostname : String?

    @[JSON::Field(emit_null: true)]
    property ip : String?

    property started_at : String
    property ended_at : String?
    property elapsed_s : Float64?

    def initialize(
      @version : String,
      @target : String,
      @started_at : String,
      @hostname : String? = nil,
      @ip : String? = nil,
      @ended_at : String? = nil,
      @elapsed_s : Float64? = nil,
    )
    end
  end

  # The per-module results, keyed by module name in the export. Empty until a
  # module lands; each scan module adds its typed result field in its own phase,
  # named `ModuleResults` (not `Modules`) to avoid the scan-module namespace.
  class ModuleResults
    include JSON::Serializable

    STORAGE_KEYS = {"dir" => "directory_enum", "sub" => "subdomains", "ps" => "portscan", "arch" => "architecture_fingerprinting", "crawl" => "crawler"}
    FIELDS       = {
      sslinfo: "sslinfo", headers: "headers", dns: "dns", whois: "whois", portscan: "portscan",
      subdomains: "subdomains", crawler: "crawler", wayback: "wayback", directory_enum: "directory_enum",
      arch: "architecture_fingerprinting",
    }

    # Outcome envelopes override serialization without widening successful-result getters
    @[JSON::Field(ignore: true)]
    getter outcomes : Hash(String, ModuleOutcome) = {} of String => ModuleOutcome

    # Each scan module adds its typed result field here as it lands; an unset
    # (nil) field is omitted from the export, matching the Ruby run hash where a
    # module that did not run has no key.
    property sslinfo : Modules::SSLInfo::Result? = nil
    property headers : Modules::Headers::Result? = nil
    property dns : Modules::DnsEnumeration::Result? = nil
    property whois : Modules::WhoisLookup::Result? = nil
    property portscan : Modules::PortScan::Result? = nil
    property subdomains : Modules::Subdomains::Result? = nil
    property crawler : Modules::Crawler::Result? = nil
    property wayback : Modules::Wayback::Result? = nil
    property directory_enum : Modules::DirectoryEnum::Result? = nil

    @[JSON::Field(key: "architecture_fingerprinting")]
    property arch : Modules::Arch::Result? = nil

    def initialize
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        {% for field, key in FIELDS %}
          if outcome = @outcomes[{{ key }}]?
            json.field({{ key }}, outcome)
          elsif result = @{{ field.id }}
            json.field({{ key }}, result)
          end
        {% end %}
      end
    end
  end

  # The typed scan state, serialized as the parity contract. Its JSON shape
  # matches the Ruby `run` hash: meta, modules, artifacts, findings.
  class RunState
    include JSON::Serializable

    property meta : Meta
    property modules : ModuleResults
    property artifacts : Hash(String, Array(String))
    property findings : Array(Finding)

    def initialize(
      @meta : Meta,
      @modules : ModuleResults = ModuleResults.new,
      @artifacts : Hash(String, Array(String)) = {} of String => Array(String),
      @findings : Array(Finding) = [] of Finding,
    )
    end

    # Appends values under a kind, de-duplicated and keeping first-seen order.
    # The seen check is a Set, so collecting N values stays O(N).
    def add_artifact(kind : String, values : Enumerable(String)) : Nil
      list = (@artifacts[kind] ||= [] of String)
      seen = list.to_set
      values.each do |value|
        safe = TerminalText.strip_sgr(TerminalText.sanitize(value))
        list << safe if seen.add?(safe)
      end
    end
  end
end
