require "json"
require "uri"
require "../http/pool"
require "../arch/fingerprint"
require "../ui"

module Nokizaru
  module Modules
    # Architecture fingerprinting via the Wappalyzer lookup API. Requires an API
    # key (from the key store); with none, the module records a skipped result and
    # makes no request. Field names and shape match the Ruby JSON: the module
    # stores {technologies:[{name,version,categories}], status}. The result is
    # keyed "architecture_fingerprinting" in the run (see ModuleResults). Ports
    # modules/arch.rb. The API key is fetched by the runner and passed in; the UI
    # and artifact wiring attach with the runner.
    module Arch
      extend self

      LOOKUP_URL  = "https://api.wappalyzer.com/v2/lookup/"
      MAX_TIMEOUT = 12.0

      struct Technology
        include JSON::Serializable

        getter name : String
        getter version : String
        getter categories : Array(String)

        def initialize(@name : String, @version : String, @categories : Array(String))
        end
      end

      struct Result
        include JSON::Serializable

        getter technologies : Array(Technology)
        getter status : String

        def initialize(@technologies : Array(Technology), @status : String)
        end

        def self.ok(technologies : Array(Technology)) : Result
          new(technologies, "ok")
        end

        def self.skipped : Result
          new([] of Technology, "skipped_no_key")
        end

        def self.error : Result
          new([] of Technology, "error")
        end
      end

      # Renders the detected technologies for the classic output and the dashboard
      # capture: a list (first 20) with version/categories, a truncation note, and
      # the total; or a skip/error/none line. Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Architecture Fingerprinting")
        case result.status
        when "skipped_no_key" then UI.row(:error, "Skipping Architecture Fingerprinting", "API key not found!")
        when "error"          then UI.line(:error, "Architecture Fingerprinting Exception")
        else                       present_technologies(result.technologies)
        end
      end

      private def present_technologies(technologies : Array(Technology)) : Nil
        if technologies.empty?
          UI.line(:error, "No technologies identified")
          return
        end

        UI.section("Architecture Fingerprinting Results :")
        technologies.first(20).each { |tech| UI.output.puts(UI.safe(technology_line(tech))) }
        UI.line(:info, "Results truncated...") if technologies.size > 20
        UI.blank_line
        UI.row(:info, "Total Unique Technologies Found", technologies.size.to_s)
      end

      private def technology_line(tech : Technology) : String
        details = [] of String
        details << "version: #{tech.version}" unless tech.version.empty?
        details << "categories: #{tech.categories.join(", ")}" unless tech.categories.empty?
        suffix = details.empty? ? "" : " (#{details.join(" | ")})"
        "#{tech.name}#{suffix}"
      end

      def collect(target : String, pool : Http::Pool, api_key : String?, timeout_s : Float64, transport : Proc(String, Http::Options, Http::Result)? = nil) : Result
        page = fetch(target, page_options(timeout_s), pool, transport)
        local = page.success? ? Fingerprint.detect(page) : [] of Technology
        remote = wappalyzer(target, pool, api_key, timeout_s, transport)
        merged = Parser.dedupe(local + remote)
        return Result.ok(merged) unless merged.empty?
        return Result.error if page.error?

        Result.ok([] of Technology)
      rescue
        Result.error
      end

      # Queries the Wappalyzer lookup API when a key is present, returning its
      # technologies; with no key it is a no-op so local fingerprinting stands
      # alone. A non-200 or transport error yields nothing (local still applies).
      private def wappalyzer(target : String, pool : Http::Pool, api_key : String?, timeout_s : Float64, transport : Proc(String, Http::Options, Http::Result)?) : Array(Technology)
        return [] of Technology if api_key.nil? || api_key.strip.empty?

        options = Http::Options.new(
          headers: ::HTTP::Headers{"x-api-key" => api_key},
          timeout_s: {timeout_s, MAX_TIMEOUT}.min,
          verify_ssl: true,
          follow_redirects: true,
        )
        result = fetch(request_url(target), options, pool, transport)
        return [] of Technology if result.error? || result.status != 200

        Parser.parse(result.body || "")
      rescue
        [] of Technology
      end

      private def page_options(timeout_s : Float64) : Http::Options
        Http::Options.new(timeout_s: {timeout_s, MAX_TIMEOUT}.min, verify_ssl: true, follow_redirects: true)
      end

      private def fetch(url : String, options : Http::Options, pool : Http::Pool, transport : Proc(String, Http::Options, Http::Result)?) : Http::Result
        transport ? transport.call(url, options) : pool.get(url, options)
      end

      # The lookup URL carrying the target as the `urls` query parameter.
      def request_url(target : String) : String
        "#{LOOKUP_URL}?#{URI::Params.build(&.add("urls", target))}"
      end

      # Parses the Wappalyzer JSON (an object or an array of objects) into typed,
      # deduped technologies. JSON::Any is used only at this decode boundary; the
      # model it produces is typed. Complexity: O(n) extract + dedupe through a
      # Hash, O(n log n) final sort, over the bounded response.
      module Parser
        extend self

        def parse(body : String) : Array(Technology)
          data = JSON.parse(body)
          rows = data.as_a? || [data]
          dedupe(rows.flat_map { |row| row_technologies(row) })
        rescue JSON::ParseException
          [] of Technology
        end

        private def row_technologies(row : JSON::Any) : Array(Technology)
          entries = row["technologies"]?.try(&.as_a?) || [] of JSON::Any
          entries.map { |entry| normalized_technology(entry) }
        end

        private def normalized_technology(entry : JSON::Any) : Technology
          Technology.new(
            name: string_field(entry, "name"),
            version: string_field(entry, "version"),
            categories: normalized_categories(entry["categories"]?),
          )
        end

        private def string_field(any : JSON::Any, key : String) : String
          value = any[key]?
          return "" if value.nil? || value.raw.nil?

          value.as_s? || value.raw.to_s
        end

        private def normalized_categories(any : JSON::Any?) : Array(String)
          entries = any.try(&.as_a?) || [] of JSON::Any
          entries.compact_map do |value|
            name = category_name(value)
            name unless name.empty?
          end
        end

        private def category_name(value : JSON::Any) : String
          table = value.as_h?
          return (value.as_s? || value.raw.to_s) if table.nil?

          field = table["name"]?
          field.nil? ? "" : (field.as_s? || field.raw.to_s)
        end

        # Merges duplicate technologies by name (case-insensitive), unioning
        # categories and keeping the first non-empty version. Public so local
        # fingerprinting and the Wappalyzer parse can be deduped together.
        def dedupe(technologies : Array(Technology)) : Array(Technology)
          table = {} of String => Technology
          technologies.each { |entry| merge_entry(table, entry) }
          table.values.sort_by!(&.name.downcase)
        end

        private def merge_entry(table : Hash(String, Technology), entry : Technology) : Nil
          name = entry.name.strip
          return if name.empty?

          key = name.downcase
          existing = table[key]?
          if existing
            categories = (existing.categories + entry.categories).reject(&.empty?).uniq!
            version = existing.version.empty? ? entry.version : existing.version
            table[key] = Technology.new(existing.name, version, categories)
          else
            table[key] = Technology.new(name, entry.version, entry.categories.reject(&.empty?).uniq!)
          end
        end
      end
    end
  end
end
