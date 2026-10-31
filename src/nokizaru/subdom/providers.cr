require "base64"
require "./provider"
require "./crtsh_pg"

module Nokizaru
  module Subdom
    # The curated subdomain sources: a trusted keyless core (CT + passive DNS +
    # URL-derived) plus key-enriched sources that run only when a key is present.
    # Deliberately leaner than subfinder's catalog; we offer the mature, reliable
    # providers rather than every source in existence. Nothing here hits the
    # network in a test: build/parse are pure and unit-tested with canned bodies
    # (crt.sh's Postgres path is injected).

    # ---- keyless core ----

    # https://anubisdb.com - public passive DNS; 204/404/300 mean "none".
    class AnubisDB < Provider
      def name : String
        "AnubisDB"
      end

      def empty_statuses : Array(Int32)
        [204, 404, 300]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://anubisdb.com/anubis/subdomains/#{host}")
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body))
      end
    end

    # https://certspotter.com - public CT issuance search (rate-limited keyless).
    class CertSpotter < Provider
      def name : String
        "CertSpotter"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new(with_params("https://api.certspotter.com/v1/issuances",
          [{"domain", host}, {"expand", "dns_names"}, {"include_subdomains", "true"}]))
      end

      def parse(host : String, body : String) : Array(String)
        names = [] of String
        (JSON.parse(body).as_a? || [] of JSON::Any).each { |entry| names.concat(as_strings(entry["dns_names"]?)) }
        names
      end
    end

    # https://crt.sh - public CT log search. Primary path is the certwatch
    # Postgres backend (reliable, rich); the HTTP JSON frontend is a fallback
    # because it load-sheds (502s) and is slow. name_value may be newline-joined.
    class CrtSh < Provider
      RETRYABLE    = {502, 503, 504}
      MAX_ATTEMPTS = 3
      # The live Postgres query; injectable so specs never touch the network.
      LIVE_PG = ->(host : String, remaining : Float64) { CrtShPg.query(host, remaining) }

      def initialize(@pg_query : Proc(String, Float64, Array(String)) = LIVE_PG)
      end

      def name : String
        "crt.sh"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"Accept" => "application/json"}
        Request.new("https://crt.sh/?dNSName=%25.#{host}&output=json", headers: headers)
      end

      # Try Postgres first; on any connection or protocol failure fall through to
      # the HTTP endpoint so crt.sh still contributes when the DB is unreachable.
      def fetch(host : String, operation : Operation, keys : Hash(String, String)) : Nil
        if names = pg_names(host, operation.remaining)
          operation.names.concat(names)
          return unless names.empty?
        end
        http_fetch(host, operation, keys)
      end

      private def pg_names(host : String, remaining : Float64) : Array(String)?
        return nil if remaining <= 0

        @pg_query.call(host, remaining)
      rescue
        nil
      end

      # Retries on gateway 5xx (crt.sh load-sheds); no wall sleep so the retry
      # count is deterministic in specs, and each execute re-checks the deadline.
      private def http_fetch(host : String, operation : Operation, keys : Hash(String, String)) : Nil
        attempts = 0
        loop do
          attempts += 1
          result = operation.execute(build(host, keys))
          if result.status == 200
            operation.names.concat(parse(host, result.body || ""))
            return
          end
          raise ProviderError.new(status_label(result), failure_reason(result)) unless RETRYABLE.includes?(result.status) && attempts < MAX_ATTEMPTS
        end
      end

      def parse(host : String, body : String) : Array(String)
        names = [] of String
        (JSON.parse(body).as_a? || [] of JSON::Any).each do |entry|
          value = entry["name_value"]?.try(&.as_s?) || ""
          value.each_line { |line| stripped = line.strip; names << stripped unless stripped.empty? }
        end
        names
      end
    end

    # https://certificatedetails.com - public CT. Even its 404 page lists ~100
    # subdomains, so the body is parsed regardless of status.
    class Digitorus < Provider
      def name : String
        "Digitorus"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://certificatedetails.com/#{host}")
      end

      # 200 and 404 both carry subdomains (subfinder issue #774); any other
      # status (e.g. a Cloudflare 403) is a real block, surfaced as an error
      # rather than masked as an empty-but-healthy result.
      def fetch(host : String, operation : Operation, keys : Hash(String, String)) : Nil
        result = operation.execute(build(host, keys))
        status = result.status
        if status == 200 || status == 404
          operation.names.concat(parse(host, result.body || ""))
        else
          raise ProviderError.new(status_label(result), failure_reason(result))
        end
      end

      def parse(host : String, body : String) : Array(String)
        hosts_in(body, host)
      end
    end

    # https://hackertarget.com - public host search, CSV "sub,ip" lines.
    class HackerTarget < Provider
      def name : String
        "HackerTarget"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new(with_params("https://api.hackertarget.com/hostsearch/", [{"q", host}]))
      end

      def parse(host : String, body : String) : Array(String)
        body.lines.compact_map do |line|
          field = line.split(',', 2)[0].strip
          field.empty? ? nil : field
        end
      end
    end

    # https://rapiddns.io - public passive DNS; the full table is scraped from
    # the result HTML.
    class RapidDNS < Provider
      def name : String
        "RapidDNS"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://rapiddns.io/subdomain/#{host}?full=1")
      end

      def parse(host : String, body : String) : Array(String)
        hosts_in(body, host)
      end
    end

    # https://urlscan.io - public scan search, domain under task.domain.
    class UrlScan < Provider
      def name : String
        "UrlScan"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://urlscan.io/api/v1/search/?q=domain:#{host}")
      end

      def parse(host : String, body : String) : Array(String)
        results = JSON.parse(body)["results"]?.try(&.as_a?) || [] of JSON::Any
        results.compact_map do |entry|
          task = entry["task"]?
          task.try { |value| value["domain"]? }.try(&.as_s?)
        end.uniq!
      end
    end

    # https://web.archive.org - CDX of archived URLs for *.host; subdomains are
    # the hostnames of the returned URLs.
    class WaybackArchive < Provider
      def name : String
        "Wayback"
      end

      # Excluded from the health summary: the Internet Archive throttles this
      # service aggressively server-side, so its frequent timeouts reflect their
      # load management, not our module's health. It still enriches the results.
      def report_health? : Bool
        false
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://web.archive.org/cdx/search/cdx?url=*.#{host}/*&output=txt&fl=original&collapse=urlkey")
      end

      def parse(host : String, body : String) : Array(String)
        hosts_in(body, host)
      end
    end

    # ---- key-enriched ----

    # https://otx.alienvault.com - passive DNS (key).
    class AlienVault < Provider
      def name : String
        "AlienVault"
      end

      def key_names : Array({String, String})
        [{"alienvault", "NK_ALIENVAULT_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"X-OTX-API-KEY" => keys["alienvault"]}
        Request.new("https://otx.alienvault.com/api/v1/indicators/domain/#{host}/passive_dns", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        passive = JSON.parse(body)["passive_dns"]?.try(&.as_a?) || [] of JSON::Any
        passive.compact_map { |entry| entry["hostname"]?.try(&.as_s?) }.uniq!
      end
    end

    # https://bevigil.com - mobile-app OSINT; a source no other provider covers (key).
    class BeVigil < Provider
      def name : String
        "BeVigil"
      end

      def key_names : Array({String, String})
        [{"bevigil", "NK_BEVIGIL_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"X-Access-Token" => keys["bevigil"]}
        Request.new("https://osint.bevigil.com/api/#{host}/subdomains/", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["subdomains"]?)
      end
    end

    # https://virustotal.com (key).
    class VirusTotal < Provider
      def name : String
        "VirusTotal"
      end

      def key_names : Array({String, String})
        [{"virustotal", "NK_VT_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"x-apikey" => keys["virustotal"]}
        Request.new("https://www.virustotal.com/api/v3/domains/#{host}/subdomains", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        data = JSON.parse(body)["data"]?.try(&.as_a?) || [] of JSON::Any
        data.compact_map { |entry| entry["id"]?.try(&.as_s?) }
      end
    end

    # https://shodan.io - returns labels; qualified with the host (key).
    class Shodan < Provider
      def name : String
        "Shodan"
      end

      def key_names : Array({String, String})
        [{"shodan", "NK_SHODAN_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://api.shodan.io/dns/domain/#{host}?key=#{keys["shodan"]}")
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["subdomains"]?).map { |label| "#{label}.#{host}" }
      end
    end

    # https://projectdiscovery.io Chaos - returns labels, qualified (key).
    class Chaos < Provider
      def name : String
        "Chaos"
      end

      def key_names : Array({String, String})
        [{"chaos", "NK_CHAOS_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"Authorization" => keys["chaos"]}
        Request.new("https://dns.projectdiscovery.io/dns/#{host}/subdomains", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["subdomains"]?).reject(&.empty?).map { |label| "#{label}.#{host}" }
      end
    end

    # https://censys.io - POST certificate search, paginated (two keys).
    class Censys < Provider
      MAX_PAGES =   3
      PER_PAGE  = 100

      def name : String
        "Censys"
      end

      def key_names : Array({String, String})
        [{"censys_api_id", "NK_CENSYS_API_ID"}, {"censys_api_secret", "NK_CENSYS_API_SECRET"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        page_request(host, keys, "")
      end

      def parse(host : String, body : String) : Array(String)
        extract(host, JSON.parse(body))
      end

      # Follows the cursor for up to MAX_PAGES pages. Complexity: O(MAX_PAGES)
      # bounded requests, each parsed in one pass.
      def fetch(host : String, operation : Operation, keys : Hash(String, String)) : Nil
        cursor = ""
        MAX_PAGES.times do
          result = operation.execute(page_request(host, keys, cursor))
          raise ProviderError.new(status_label(result), failure_reason(result)) unless result.status == 200

          data = JSON.parse(result.body || "")
          operation.names.concat(extract(host, data))
          cursor = next_cursor(data)
          break if cursor.empty?
        end
      end

      private def page_request(host : String, keys : Hash(String, String), cursor : String) : Request
        auth = Base64.strict_encode("#{keys["censys_api_id"]}:#{keys["censys_api_secret"]}")
        headers = ::HTTP::Headers{"Authorization" => "Basic #{auth}", "Content-Type" => "application/json"}
        payload = {q: "names: #{host}", per_page: PER_PAGE, cursor: cursor}.to_json
        Request.new("https://search.censys.io/api/v2/certificates/search", method: "POST", headers: headers, body: payload)
      end

      private def extract(host : String, data : JSON::Any) : Array(String)
        hits = data["result"]?.try { |value| value["hits"]? }.try(&.as_a?) || [] of JSON::Any
        suffix = host.downcase
        names = [] of String
        hits.each do |hit|
          as_strings(hit["names"]?).each do |candidate|
            lowered = candidate.downcase
            names << lowered if !lowered.empty? && lowered.ends_with?(suffix)
          end
        end
        names.uniq!
      end

      private def next_cursor(data : JSON::Any) : String
        links = data["result"]?.try { |value| value["links"]? }
        links.try { |value| value["next"]? }.try(&.as_s?).to_s.strip
      end
    end

    # https://securitytrails.com - high-signal DNS dataset; labels qualified (key).
    class SecurityTrails < Provider
      def name : String
        "SecurityTrails"
      end

      def key_names : Array({String, String})
        [{"securitytrails", "NK_SECURITYTRAILS_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"APIKEY" => keys["securitytrails"]}
        Request.new("https://api.securitytrails.com/v1/domain/#{host}/subdomains", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["subdomains"]?).reject(&.empty?).map { |label| "#{label}.#{host}" }
      end
    end

    # https://api.github.com - code search; subdomains mentioned in public code
    # (dev/internal hosts leak in configs). Extracts hosts from the match text (key).
    class Github < Provider
      def name : String
        "GitHub"
      end

      def key_names : Array({String, String})
        [{"github", "NK_GITHUB_TOKEN"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{
          "Accept"        => "application/vnd.github.v3.text-match+json",
          "Authorization" => "token #{keys["github"]}",
        }
        url = with_params("https://api.github.com/search/code",
          [{"per_page", "100"}, {"q", host}, {"sort", "created"}, {"order", "asc"}])
        Request.new(url, headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        hosts_in(body, host)
      end
    end

    # https://gitlab.com - blob search; subdomains mentioned in public code (key).
    class Gitlab < Provider
      def name : String
        "GitLab"
      end

      def key_names : Array({String, String})
        [{"gitlab", "NK_GITLAB_TOKEN"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"PRIVATE-TOKEN" => keys["gitlab"]}
        url = with_params("https://gitlab.com/api/v4/search", [{"scope", "blobs"}, {"search", host}, {"per_page", "100"}])
        Request.new(url, headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        hosts_in(body, host)
      end
    end
  end
end
