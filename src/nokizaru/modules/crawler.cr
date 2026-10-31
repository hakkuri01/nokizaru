require "json"
require "../crawler/engine"
require "../crawler/result"
require "../crawler/limits"
require "../http/pool"
require "../target_intel"
require "../ui"

module Nokizaru
  module Modules
    # The crawler module entry. Resolves the target's redirect profile (reusing
    # the Headers module's when the runner passes it), then drives the crawl
    # engine to a typed result whose JSON shape matches the Ruby run hash (the
    # parity contract).
    module Crawler
      extend self

      alias Result = Nokizaru::Crawler::Result

      # Widest Ruby crawler step label ("Extracting JavaScript links"), so the
      # re-anchor and count rows align exactly as the Ruby tool rendered them.
      STEP_LABEL_WIDTH = 27
      PREVIEW_LIMIT    =  8

      # The eight link buckets previewed at the end of a crawl, in Ruby order:
      # the label and the Result accessor for each.
      PREVIEW_SECTIONS = [
        {"Robots Links", "robots_links"},
        {"Sitemap Links", "sitemap_links"},
        {"Internal Links", "internal_links"},
        {"External Links", "external_links"},
        {"Image Links", "images"},
        {"JavaScript Links", "js_links"},
        {"URLs inside JavaScript", "urls_inside_js"},
        {"URLs inside Sitemaps", "urls_inside_sitemap"},
      ]

      # Renders the crawl for the classic output and the dashboard capture: the
      # re-anchor decision, the per-bucket counts, then a bounded preview of each
      # bucket. Header bar dropped in TUI mode.
      #
      # ponytail: the Ruby tool also logged two probe-status rows ("Looking for
      # robots.txt"/"Looking for sitemap.xml", Found/Not Found). That state is a
      # collection-time fetch outcome not carried in the parity Result, so it is
      # surfaced through the progress rail during the scan rather than
      # reconstructed here; the count rows and previews are fully Result-derived.
      def present(result : Result) : Nil
        UI.module_header("Crawler")
        target = result.target
        UI.row(:plus, "Re-Anchor", "#{target.effective} (#{target.reason_code})", label_width: STEP_LABEL_WIDTH)
        present_counts(result)
        UI.blank_line
        PREVIEW_SECTIONS.each { |(label, bucket)| preview(label, bucket_links(result, bucket)) }
      end

      private def present_counts(result : Result) : Nil
        UI.rows(:info, [
          {"Extracting robots links", result.robots_links.size.to_s},
          {"Extracting CSS links", result.css_links.size.to_s},
          {"Extracting JavaScript links", result.js_links.size.to_s},
          {"Extracting internal links", result.internal_links.size.to_s},
          {"Extracting external links", result.external_links.size.to_s},
          {"Extracting image links", result.images.size.to_s},
          {"Crawling Sitemaps", result.urls_inside_sitemap.size.to_s},
          {"Crawling Javascripts", result.urls_inside_js.size.to_s},
        ])
      end

      private def bucket_links(result : Result, bucket : String) : Array(String)
        case bucket
        when "robots_links"        then result.robots_links
        when "sitemap_links"       then result.sitemap_links
        when "internal_links"      then result.internal_links
        when "external_links"      then result.external_links
        when "images"              then result.images
        when "js_links"            then result.js_links
        when "urls_inside_js"      then result.urls_inside_js
        when "urls_inside_sitemap" then result.urls_inside_sitemap
        else                            [] of String
        end
      end

      private def preview(label : String, links : Array(String)) : Nil
        values = links.uniq
        return if values.empty?

        UI.tree_header("#{label} Preview")
        rows = values.first(PREVIEW_LIMIT).map { |link| {"URL", link} }
        remaining = values.size - PREVIEW_LIMIT
        rows << {"More", remaining.to_s} if remaining > 0
        UI.tree_rows(rows)
      end

      def collect(
        target : String,
        pool : Http::Pool = Http::Pool.new,
        request_headers : ::HTTP::Headers = ::HTTP::Headers.new,
        profile : TargetIntel::Profile? = nil,
        wayback_seeds : Array(String) = [] of String,
      ) : Result
        resolved = profile || compute_profile(target, pool, request_headers)
        Nokizaru::Crawler::Engine.new(pool, request_headers, wayback_seeds).run(target, resolved)
      end

      # When the runner has not already profiled the target (via Headers), fetch
      # it once with redirects off and build the profile from that response, as
      # the Ruby resolve_anchor fallback did.
      private def compute_profile(target : String, pool : Http::Pool, request_headers : ::HTTP::Headers) : TargetIntel::Profile
        options = Http::Options.new(
          headers: request_headers,
          timeout_s: Nokizaru::Crawler::TIMEOUT,
          follow_redirects: false,
        )
        TargetIntel.profile(target, pool.get(target, options))
      end
    end
  end
end
