require "json"
require "uri"
require "../whois/client"
require "../http/pool"
require "../ui"

module Nokizaru
  module Modules
    # WHOIS lookup with an RDAP fallback. Ports modules/whois.rb: query the
    # registry over TCP 43 (the hand-rolled Whois::Client), classify the text,
    # and when it is retired/unsupported/unusable fall back to rdap.org over the
    # HTTP layer. The result shape matches the Ruby run hash (the parity
    # contract): a `whois` text plus status/source, or RDAP summary fields, or a
    # degraded marker. UI rendering and the nameserver/suffix wiring are
    # assembled with the runner.
    module WhoisLookup
      extend self

      # Line-anchored negative replies (matched per line, default flags, so `^$`
      # bind the line and `.` excludes newlines, as the Ruby /ix patterns did).
      NOT_FOUND   = /^\s*(?:[%#]\s*)?(?:no\s+match\s+for|not\s+found\b|no\s+data\s+found\b|no\s+entries\s+found\b|no\s+object\s+found\b|domain\s+.{0,255}\s+not\s+found\b|the\s+queried\s+object\s+does\s+not\s+exist\b|no\s+match!!\s*$)/i
      UNSUPPORTED = /^\s*(?:[%#]\s*)?(?:no\s+whois\s+server|whois\s+(?:service\s+)?(?:is\s+)?not\s+(?:available|supported))/i
      # A referral to RDAP, matched anywhere in the whole text (no anchors).
      RDAP_REFERRAL = /(?:whois.{0,40}(?:retired|discontinued|unsupported)|(?:use|refer\w*|transition\w*).{0,40}rdap)/i
      # Inline "Domain Name: value" variants (per line).
      DOMAIN_INLINE = [
        /^\s*Domain(?: Name)?[.]*:[ \t]*(\S+)[ \t]*\r?$/i,
        /^\s*(?:a\.\s*)?\[Domain Name\][ \t]+(\S+)[ \t]*\r?$/i,
      ]
      # The two-line "Domain name:" header then an indented value.
      DOMAIN_HEADER  = /^\s*Domain name:[ \t]*\r?$/i
      INDENTED_VALUE = /^[ \t]+(\S+)[ \t]*\r?$/

      NO_DATA_MESSAGE = "No usable registration data returned"

      # One RDAP event (eventAction/eventDate), serialized with those keys.
      struct Event
        include JSON::Serializable

        getter action : String
        getter date : String

        def initialize(@action : String, @date : String)
        end
      end

      # The typed WHOIS result. Every field is nilable and omitted from the JSON
      # when unset, mirroring the Ruby hash that gained keys through merges, so
      # the on-wire shape matches per scenario.
      class Result
        include JSON::Serializable

        property whois : String? = nil

        @[JSON::Field(key: "Error")]
        property error : String? = nil

        @[JSON::Field(key: "error")]
        property error_detail : String? = nil

        property status : String? = nil
        property source : String? = nil
        property reasons : Array(String)? = nil
        property domain : String? = nil
        property handle : String? = nil
        property registration_status : Array(String)? = nil
        property events : Array(Event)? = nil
        property nameservers : Array(String)? = nil

        def initialize
        end
      end

      # The RDAP summary extracted from a domain object, applied onto a Result.
      struct Summary
        getter domain : String
        getter handle : String
        getter registration_status : Array(String)
        getter events : Array(Event)
        getter nameservers : Array(String)

        def initialize(@domain, @handle, @registration_status, @events, @nameservers)
        end
      end

      # Renders the lookup for the classic output and the dashboard capture: raw
      # whois text as key/value rows (plus misc lines), an RDAP summary as rows,
      # or an error line when neither is present. Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Whois Lookup")
        shown = false
        raw = result.whois
        if raw && !raw.strip.empty?
          present_whois_text(raw)
          shown = true
        end
        if result.domain
          present_rdap(result)
          shown = true
        end
        return if shown

        error = result.error
        UI.line(:error, "Error : #{error}") if error
      end

      private def present_whois_text(raw : String) : Nil
        pairs = [] of Tuple(String, String?)
        misc = [] of String
        raw.each_line do |line|
          clean = line.strip
          next if clean.empty?

          if clean.includes?(':')
            key, _, value = clean.partition(':')
            pairs << {key.strip, value.strip}
          else
            misc << normalize_misc_line(clean)
          end
        end
        UI.rows(:info, pairs) unless pairs.empty?
        misc.each { |line| UI.line(:info, line) }
      end

      private def present_rdap(result : Result) : Nil
        events = (result.events || [] of Event).map { |event| "#{event.action}: #{event.date}" }.join(", ")
        UI.rows(:info, [
          {"Domain", result.domain},
          {"Handle", result.handle},
          {"Status", (result.registration_status || [] of String).join(", ")},
          {"Events", events},
          {"Nameservers", (result.nameservers || [] of String).join(", ")},
        ] of Tuple(String, String?))
      end

      private def normalize_misc_line(line : String) : String
        line.sub(/\ANo match for "([^"]+)"\.\z/i) { "No match for #{$1.downcase}" }
      end

      def collect(domain : String, tld : String, whois : Whois::Client = Whois::Client.new, rdap : RdapClient = RdapClient.new) : Result
        query = build_query(domain, tld)
        finish(query, fetch_whois(query, tld, whois), rdap)
      end

      def build_query(domain : String, tld : String) : String
        tld.empty? ? domain : "#{domain}.#{tld}"
      end

      # Classifies the WHOIS text: a RDAP referral, a matching domain field
      # (registered), a negative reply, an unsupported marker, empty, or
      # otherwise unusable. Public so the regexes get direct unit coverage.
      def classify(raw : String, query : String) : Symbol
        text = raw.strip
        return :retired if text.matches?(RDAP_REFERRAL)
        return :usable if matching_domain_field?(text, query)
        return :not_found if any_line_matches?(text, NOT_FOUND)
        return :unsupported if any_line_matches?(text, UNSUPPORTED)
        return :no_data if text.empty?

        :unusable
      end

      private def fetch_whois(query : String, tld : String, whois : Whois::Client) : {String, Symbol, String?}
        raw = normalize(whois.lookup(query, tld))
        {raw, classify(raw, query), nil}
      rescue Whois::ServerError
        {"", :unsupported, "This domain suffix is not supported."}
      rescue ex : Whois::ConnectionError
        {"", :transport_error, ex.message}
      rescue ex
        {"", :unusable, ex.message}
      end

      private def finish(query : String, outcome : {String, Symbol, String?}, rdap : RdapClient) : Result
        raw, classification, legacy = outcome
        result = Result.new
        result.whois = raw
        result.error = legacy unless legacy.nil?

        case classification
        when :usable
          result.status, result.source = "registered", "whois"
        when :not_found
          result.status, result.source = "not_found", "whois"
        else
          rdap_fallback(query, result, "whois_#{classification}", rdap)
        end
        result
      end

      private def rdap_fallback(query : String, result : Result, reason : String, rdap : RdapClient) : Nil
        response = rdap.fetch(query)
        return degrade(result, reason, "rdap_transport_error") if response.nil? || response.error?

        status = response.status
        return handle_rdap_404(result, reason, response.body) if status == 404

        failure = rdap_failure_reason(status)
        return degrade(result, reason, failure) if failure

        apply_rdap(query, result, reason, response.body)
      rescue
        degrade(result, reason, "rdap_transport_error")
      end

      private def handle_rdap_404(result : Result, reason : String, body : String?) : Nil
        return degrade(result, reason, "rdap_no_service") if rdap_no_service?(body)

        result.status, result.source, result.reasons = "not_found", "rdap", [reason]
      end

      private def apply_rdap(query : String, result : Result, reason : String, body : String?) : Nil
        summary = parse_rdap(body, query)
        return degrade(result, reason, summary) if summary.is_a?(String)

        result.error = nil
        result.error_detail = nil
        result.domain = summary.domain
        result.handle = summary.handle
        result.registration_status = summary.registration_status
        result.events = summary.events
        result.nameservers = summary.nameservers
        result.status, result.source, result.reasons = "registered", "rdap", [reason]
      end

      private def degrade(result : Result, whois_reason : String, rdap_reason : String) : Nil
        result.status = "degraded"
        result.source = "rdap"
        result.error ||= NO_DATA_MESSAGE
        result.error_detail = NO_DATA_MESSAGE
        result.reasons = [whois_reason, rdap_reason]
      end

      private def rdap_failure_reason(status : Int32?) : String?
        return nil if status == 200
        return "rdap_rate_limited" if status == 429
        return "rdap_server_error" if status && status >= 500

        "rdap_http_error"
      end

      private def rdap_no_service?(body : String?) : Bool
        hash = JSON.parse(body || "").as_h?
        return false if hash.nil?

        hash["title"]?.try(&.as_s?).try(&.downcase) == "no rdap service is available for this resource"
      rescue JSON::ParseException
        false
      end

      # Parses an RDAP domain object into a Summary, or returns a reason string
      # when the body is malformed or names a different domain.
      private def parse_rdap(body : String?, query : String) : Summary | String
        hash = JSON.parse(body || "").as_h?
        return "rdap_malformed_response" if hash.nil?
        return "rdap_malformed_response" unless hash["objectClassName"]?.try(&.as_s?).try(&.downcase) == "domain"

        expected = normalize_domain(query)
        names = [hash["ldhName"]?, hash["unicodeName"]?].compact_map(&.try(&.as_s?)).map { |name| normalize_domain(name) }
        return "rdap_domain_mismatch" unless names.includes?(expected)

        build_summary(hash, expected)
      rescue JSON::ParseException
        "rdap_malformed_response"
      end

      private def build_summary(hash : Hash(String, JSON::Any), domain : String) : Summary
        Summary.new(
          domain: domain,
          handle: hash["handle"]?.try(&.as_s?) || "",
          registration_status: string_array(hash["status"]?),
          events: events_of(hash["events"]?),
          nameservers: nameservers_of(hash["nameservers"]?),
        )
      end

      private def string_array(value : JSON::Any?) : Array(String)
        array = value.try(&.as_a?)
        array.nil? ? [] of String : array.compact_map(&.as_s?)
      end

      private def events_of(value : JSON::Any?) : Array(Event)
        array = value.try(&.as_a?)
        return [] of Event if array.nil?

        array.compact_map { |item| normalize_event(item) }
      end

      private def normalize_event(item : JSON::Any) : Event?
        obj = item.as_h?
        return nil if obj.nil?

        action = obj["eventAction"]?.try(&.as_s?) || ""
        date = obj["eventDate"]?.try(&.as_s?) || ""
        action.empty? || date.empty? ? nil : Event.new(action, date)
      end

      private def nameservers_of(value : JSON::Any?) : Array(String)
        array = value.try(&.as_a?)
        return [] of String if array.nil?

        seen = Set(String).new
        servers = [] of String
        array.each do |item|
          name = normalize_nameserver(item)
          servers << name if name && seen.add?(name)
        end
        servers
      end

      private def normalize_nameserver(item : JSON::Any) : String?
        obj = item.as_h?
        return nil if obj.nil?

        name = obj["ldhName"]?.try(&.as_s?) || obj["unicodeName"]?.try(&.as_s?)
        normalized = normalize_domain(name)
        normalized.empty? ? nil : normalized
      end

      private def matching_domain_field?(text : String, query : String) : Bool
        expected = normalize_domain(query)
        return false if expected.empty?

        inline_match?(text, expected) || header_value_match?(text, expected)
      end

      private def inline_match?(text : String, expected : String) : Bool
        text.each_line.any? do |line|
          DOMAIN_INLINE.any? do |pattern|
            match = line.match(pattern)
            !match.nil? && normalize_domain(match[1]) == expected
          end
        end
      end

      private def header_value_match?(text : String, expected : String) : Bool
        lines = text.lines
        lines.each_with_index do |line, index|
          next unless line.matches?(DOMAIN_HEADER)

          value = lines[index + 1]?.try(&.match(INDENTED_VALUE))
          return true if value && normalize_domain(value[1]) == expected
        end
        false
      end

      private def any_line_matches?(text : String, pattern : Regex) : Bool
        text.each_line.any?(&.matches?(pattern))
      end

      private def normalize_domain(value : String?) : String
        value.to_s.strip.downcase.rchop('.')
      end

      # WHOIS servers return assorted encodings; scrub invalid bytes to a "?" so
      # the text is valid UTF-8 for storage and export, as the Ruby tool did, and
      # strip the escapes and bidi overrides a hostile server could plant in a
      # record that lands in a report file. Line breaks are content here.
      private def normalize(text : String) : String
        TerminalText.plain_block(text.scrub("?"))
      end
    end

    # The rdap.org fallback client over the HTTP layer. Its own small pool and
    # origin, both injectable so a loopback fixture can stand in for rdap.org.
    struct RdapClient
      RDAP_ORIGIN = "https://rdap.org"
      TIMEOUT     = 10.0

      def initialize(@origin : String = RDAP_ORIGIN, @pool : Http::Pool = Http::Pool.new, @timeout_s : Float64 = TIMEOUT)
      end

      def fetch(query : String) : Http::Result?
        url = "#{@origin}/domain/#{URI.encode_www_form(query)}"
        headers = ::HTTP::Headers{"Accept" => "application/rdap+json"}
        @pool.get(url, Http::Options.new(headers: headers, timeout_s: @timeout_s))
      rescue
        nil
      end
    end
  end
end
