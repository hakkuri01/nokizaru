require "xml"
require "./limits"
require "./result"
require "./budget"
require "./url_rules"
require "./fetcher"
require "./links"
require "./sitemaps"
require "./javascript"
require "./stats"
require "../target_intel"
require "../http/pool"

module Nokizaru
  module Crawler
    # Orchestrates one crawl: re-anchor the target, fetch the landing page, pull
    # links from the HTML and robots/sitemaps, crawl the sitemap graph and
    # same-scope JavaScript, then compute the stats and high-signal ranking.
    # Ports crawler.rb's `call` plus crawler/core.rb's orchestration. One scan's
    # worth of work: the page is parsed once, every collection is capped, and the
    # budget bounds the deep crawl.
    class Engine
      WAYBACK_SEED_CAP = 10

      def initialize(@pool : Http::Pool, @request_headers : ::HTTP::Headers, @wayback_seeds : Array(String) = [] of String)
        @fetcher = Fetcher.new(@pool)
        @budget = Budget.new
      end

      def run(target : String, profile : TargetIntel::Profile) : Result
        anchor = TargetIntel.reanchor_decision(target, profile)
        info = Target.new(
          original: target,
          effective: anchor.effective_target,
          reanchored: anchor.reanchor?,
          reason: anchor.reason,
          reason_code: anchor.reason_code,
        )
        status = MainFetch.new(@fetcher, @request_headers).run(anchor.effective_target)
        status.ok? ? success(info, status) : failure(info, status)
      ensure
        @fetcher.sitemap_seed = nil
      end

      private def failure(info : Target, status : FetchStatus) : Result
        result = Result.new(info, status.outcome)
        apply_fetch_envelope(result, status)
        result.error = status.message
        result.failure_reason = status.failure_reason
        result.http_status = status.http_status
        result.error_class = status.error_class
        result
      end

      private def success(info : Target, status : FetchStatus) : Result
        page_url = status.effective_url
        info.effective = page_url
        result = Result.new(info, status.outcome)
        apply_fetch_envelope(result, status)

        headers = status.request_headers
        populate_page_links(result, XML.parse_html(status.body || ""), page_url, headers)

        counts = surface_of(result)
        @budget.apply(counts)
        populate_deep_links(result, page_url, headers, counts)
        populate_wayback_seeds(result, page_url, headers)

        result.high_signal_urls = Statistics.high_signal(result)
        result.stats = Statistics.calculate(result, @budget.crawl_mode, @budget.notes.dup)
        result.status = "degraded" if @budget.status_degraded?
        result
      end

      private def populate_page_links(result : Result, doc : XML::Node, page_url : String, headers : ::HTTP::Headers) : Nil
        base_url = UrlRules.base_url_for(page_url)
        links = Links.new(@fetcher, headers, @budget).extract(doc, page_url, base_url)
        result.robots_links = links.robots_links
        result.sitemap_links = links.sitemap_links
        result.css_links = links.css_links
        result.js_links = links.js_links
        result.internal_links = links.internal_links
        result.external_links = links.external_links
        result.images = links.images
      end

      private def populate_deep_links(result : Result, page_url : String, headers : ::HTTP::Headers, counts : Surface) : Nil
        sitemap_urls, updated = Sitemaps.new(@fetcher, headers, @budget, counts).crawl(result.sitemap_links, page_url)
        result.urls_inside_sitemap = sitemap_urls
        result.sitemap_links = updated
        result.urls_inside_js = JavaScript.new(headers, @budget, counts).crawl(result.js_links, page_url)
      end

      private def surface_of(result : Result) : Surface
        Surface.new(
          internal: result.internal_links.size,
          external: result.external_links.size,
          images: result.images.size,
          sitemap: result.sitemap_links.size,
          js: result.js_links.size,
          robots: result.robots_links.size,
        )
      end

      # Historic URLs from the Wayback module are crawled as extra same-scope
      # seeds: a page the site served before but no longer links is fetched here,
      # confirmed live, and its own links extracted and merged, so the crawl
      # reaches surface the current link graph has dropped. Bounded by a small
      # seed cap and the shared budget; same-scope only (no off-site fetches).
      private def populate_wayback_seeds(result : Result, page_url : String, headers : ::HTTP::Headers) : Nil
        return if @wayback_seeds.empty?

        scope_host = URI.parse(page_url).host || ""
        @wayback_seeds.first(WAYBACK_SEED_CAP).each do |url|
          next unless same_scope_seed?(url, scope_host)

          fetch = @fetcher.fetch_following(url, headers)
          next unless fetch.success?

          live = fetch.effective_url
          result.internal_links << live unless result.internal_links.includes?(live)
          body = fetch.result.try(&.body)
          next if body.nil?

          links = Links.new(@fetcher, headers, @budget).extract(XML.parse_html(body), live, UrlRules.base_url_for(live))
          result.internal_links.concat(links.internal_links)
        end
        result.internal_links.uniq!
      end

      private def same_scope_seed?(url : String, scope_host : String) : Bool
        host = URI.parse(url).host
        !host.nil? && TargetIntel.same_scope_host?(scope_host, host)
      rescue
        false
      end

      private def apply_fetch_envelope(result : Result, status : FetchStatus) : Nil
        result.fetch = status.profiles
        result.active_user_agent = status.active_user_agent
        result.canonical_handoff = status.canonical_handoff
      end
    end
  end
end
