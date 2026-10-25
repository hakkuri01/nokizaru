require "uri"
require "set"
require "./limits"
require "./url_rules"
require "./fetcher"
require "./budget"
require "./concurrency"

module Nokizaru
  module Crawler
    # Pulls absolute URLs out of same-scope JavaScript files. Ports
    # crawler/javascript.rb. Each JS body is fetched once and scanned with a
    # linear character-class regex; only in-scope http(s) URLs are kept, capped
    # per file and overall. Complexity: at most `max_js_targets` fetches over the
    # bounded fiber pool, each an O(bytes) scan; dedup is a Set, the overall list
    # is capped at `max_js_urls_total`.
    class JavaScript
      # A linear-time match (character class, no backtracking construct) for an
      # absolute URL embedded in a script body.
      URL_PATTERN = /https?:\/\/[\w\-.~:\/?#\[\]@!$&'()*+,;=%]+/

      # A root-relative endpoint path in a quoted script literal, e.g.
      # fetch("/api/v1/users"). The first char after the leading slash must be a
      # word char so "//cdn" (protocol-relative) and "/./" noise do not match.
      # Character classes only, no backtracking construct: safe on untrusted JS.
      REL_PATTERN = /["'`](\/[A-Za-z0-9_][\w\-.~\/]*)/

      # Trailing string/structure punctuation to trim off a captured URL.
      TRAILING = /["'`,;)\]]+\z/

      def initialize(@request_headers : ::HTTP::Headers, @budget : Budget, @counts : Surface)
      end

      def crawl(js_links : Array(String), page_url : String) : Array(String)
        @budget.apply(@counts)
        return [] of String if @budget.exhausted?

        targets = scoped_targets(js_links, page_url)
        return [] of String if targets.empty?

        collect(targets, page_url)
      end

      private def collect(targets : Array(String), page_url : String) : Array(String)
        urls = [] of String
        seen = Set(String).new
        mutex = Mutex.new
        cap = @budget.max_js_urls_total
        Concurrency.each_concurrently(targets) do |js, fetcher|
          next if @budget.exhausted?

          extracted = extract(js, page_url, fetcher)
          mutex.synchronize do
            extracted.each do |url|
              break if urls.size >= cap

              urls << url if seen.add?(url)
            end
          end
        end
        urls
      end

      private def scoped_targets(js_links : Array(String), page_url : String) : Array(String)
        host = UrlRules.target_host(page_url)
        seen = Set(String).new
        scoped = [] of String
        js_links.each do |url|
          next unless seen.add?(url)
          next unless UrlRules.same_scope_url?(url, host)

          scoped << url
          break if scoped.size >= @budget.max_js_targets
        end
        scoped
      end

      private def extract(js_url : String, page_url : String, fetcher : Fetcher) : Array(String)
        headers = UrlRules.origin_headers(js_url, page_url, @request_headers)
        result = fetcher.get(js_url, headers, USER_AGENT)
        return [] of String unless success_2xx?(result)

        body = result.body || ""
        absolute = body.scan(URL_PATTERN).map(&.[0])
        normalize_extracted(absolute + relative_endpoints(body, page_url), page_url)
      rescue
        [] of String
      end

      # Resolves root-relative endpoint paths found in a script body against the
      # page origin, so fetch("/api/v1/users") becomes a scoped absolute URL that
      # normalize_extracted can scope-check and dedupe alongside the absolute
      # hits. O(bytes) over the already-capped body.
      private def relative_endpoints(body : String, page_url : String) : Array(String)
        base = URI.parse(UrlRules.base_url_for(page_url))
        resolved = [] of String
        body.scan(REL_PATTERN) do |match|
          path = match[1]?
          next if path.nil?

          resolved << base.resolve(path).to_s
        end
        resolved
      rescue
        [] of String
      end

      private def normalize_extracted(found : Array(String), page_url : String) : Array(String)
        host = UrlRules.target_host(page_url)
        seen = Set(String).new
        values = [] of String
        found.each do |raw|
          cleaned = sanitize(raw)
          next if cleaned.empty?
          next unless UrlRules.same_scope_url?(cleaned, host)

          values << cleaned if seen.add?(cleaned)
          break if values.size >= MAX_JS_URLS_PER_FILE
        end
        values
      rescue
        [] of String
      end

      private def sanitize(url : String) : String
        cleaned = url.sub(TRAILING, "")
        return "" if cleaned.empty?

        uri = URI.parse(cleaned)
        scheme = uri.scheme
        host = uri.host
        return "" unless scheme == "http" || scheme == "https"
        return "" if host.nil? || host.empty?

        cleaned
      rescue
        ""
      end

      private def success_2xx?(result : Http::Result) : Bool
        return false if result.error?

        status = result.status
        !status.nil? && status >= 200 && status < 300
      end
    end
  end
end
