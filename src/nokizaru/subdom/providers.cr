require "base64"
require "./provider"

module Nokizaru
  module Subdom
    # The 17 subdomain sources, each porting one archive subdomain_module. The
    # public ones (first five groups) need no key; the rest declare their key(s)
    # and are skipped when absent. Nothing here hits the network in a test: the
    # parse/build methods are pure and are unit-tested with canned bodies.

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

    # https://threatminer.org - public passive DNS, results under "results".
    class ThreatMiner < Provider
      def name : String
        "ThreatMiner"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new(with_params("https://api.threatminer.org/v2/domain.php", [{"q", host}, {"rt", "5"}]))
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["results"]?)
      end
    end

    # https://certspotter.com - public CT issuance search.
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

    # https://crt.sh - public CT log search; name_value may be newline-joined.
    class CrtSh < Provider
      def name : String
        "crt.sh"
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new("https://crt.sh/?dNSName=%25.#{host}&output=json")
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

    # https://bevigil.com (key).
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

    # https://graph.facebook.com - CT (key).
    class FacebookCT < Provider
      def name : String
        "Facebook"
      end

      def key_names : Array({String, String})
        [{"facebook", "NK_FB_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        Request.new(with_params("https://graph.facebook.com/certificates",
          [{"query", host}, {"fields", "domains"}, {"access_token", keys["facebook"]}]))
      end

      def parse(host : String, body : String) : Array(String)
        data = JSON.parse(body)["data"]?.try(&.as_a?) || [] of JSON::Any
        names = [] of String
        data.each { |entry| names.concat(as_strings(entry["domains"]?)) }
        names
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

    # https://binaryedge.io (key).
    class BinaryEdge < Provider
      def name : String
        "BinaryEdge"
      end

      def key_names : Array({String, String})
        [{"binedge", "NK_BINEDGE_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"X-key" => keys["binedge"]}
        Request.new("https://api.binaryedge.io/v2/query/domains/subdomain/#{host}", headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        as_strings(JSON.parse(body)["events"]?)
      end
    end

    # https://zoomeye.hk (key).
    class ZoomEye < Provider
      def name : String
        "ZoomEye"
      end

      def key_names : Array({String, String})
        [{"zoomeye", "NK_ZOOMEYE_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"API-KEY" => keys["zoomeye"], "User-Agent" => "curl"}
        Request.new(with_params("https://api.zoomeye.hk/domain/search", [{"q", host}, {"type", "0"}]), headers: headers)
      end

      def parse(host : String, body : String) : Array(String)
        list = JSON.parse(body)["list"]?.try(&.as_a?) || [] of JSON::Any
        list.compact_map { |entry| entry["name"]?.try(&.as_s?) }
      end
    end

    # https://netlas.io - POST query (key).
    class Netlas < Provider
      def name : String
        "Netlas"
      end

      def key_names : Array({String, String})
        [{"netlas", "NK_NETLAS_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        headers = ::HTTP::Headers{"X-API-Key" => keys["netlas"], "Content-Type" => "application/json"}
        payload = {q: "domain: *.#{host}", fields: ["domain"], source_type: "include", size: "200"}.to_json
        Request.new("https://app.netlas.io/api/domains/download/", method: "POST", headers: headers, body: payload)
      end

      def parse(host : String, body : String) : Array(String)
        (JSON.parse(body).as_a? || [] of JSON::Any).compact_map do |entry|
          data = entry["data"]?
          data.try { |value| value["domain"]? }.try(&.as_s?)
        end
      end
    end

    # https://hunter.how - base64 query, application-level code (key).
    class Hunter < Provider
      def name : String
        "Hunter"
      end

      def key_names : Array({String, String})
        [{"hunter", "NK_HUNTER_KEY"}]
      end

      def build(host : String, keys : Hash(String, String)) : Request
        query = Base64.strict_encode(%(domain.suffix=="#{host}"))
        params = [
          {"api-key", keys["hunter"]}, {"query", query}, {"page", "1"}, {"page_size", "1000"},
          {"start_time", Time.utc.shift(years: -1).to_s("%Y-%m-%d")}, {"end_time", (Time.utc - 2.days).to_s("%Y-%m-%d")},
        ]
        Request.new(with_params("https://api.hunter.how/search", params))
      end

      def parse(host : String, body : String) : Array(String)
        data = JSON.parse(body)
        code = data["code"]?.try(&.as_i?)
        raise ProviderError.new(code.to_s, data["message"]?.try(&.as_s?)) unless code == 200

        list = data["data"]?.try { |value| value["list"]? }.try(&.as_a?) || [] of JSON::Any
        list.compact_map { |entry| entry["domain"]?.try(&.as_s?) }
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
      def fetch(host : String, pool : Http::Pool, keys : Hash(String, String), timeout : Float64) : Array(String)
        names = [] of String
        cursor = ""
        first = true
        MAX_PAGES.times do
          request = first ? build(host, keys) : page_request(host, keys, cursor)
          first = false
          result = execute(pool, request, timeout)
          raise ProviderError.new(status_label(result), failure_reason(result)) unless result.status == 200

          body = result.body || ""
          names.concat(parse(host, body))
          cursor = next_cursor(body)
          break if cursor.empty?
        end
        names.uniq!
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

      private def next_cursor(body : String) : String
        links = JSON.parse(body)["result"]?.try { |value| value["links"]? }
        links.try { |value| value["next"]? }.try(&.as_s?).to_s.strip
      end
    end
  end
end
