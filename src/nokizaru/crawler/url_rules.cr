require "uri"
require "set"
require "../target_intel"

module Nokizaru
  module Crawler
    # Pure URL normalization and scope helpers for link extraction, plus the
    # sitemap-candidate and base-URL helpers. Every method is O(len) over a
    # single URL (or O(n) for cap_links over a list), with scope decided by the
    # registrable domain through TargetIntel.
    module UrlRules
      extend self

      # Resolves a link against the target, forcing the target to a directory
      # base so a relative link resolves under the page path, not beside it.
      # Drops in-page, javascript:, and mailto: links. Returns nil when the link
      # is empty or unresolvable.
      def url_filter(target : String, link : String?) : String?
        value = link.to_s
        return nil if value.empty?
        return nil if value.starts_with?("#") || value.starts_with?("javascript:") || value.starts_with?("mailto:")

        base = target.ends_with?("/") ? target : "#{target}/"
        URI.parse(base).resolve(value).to_s
      rescue
        nil
      end

      # A resolved link that stays within the target's registrable-domain scope.
      def internal_link(target : String, host : String?, href : String?) : String?
        normalized = url_filter(target, href)
        return nil if normalized.nil?

        uri_host = URI.parse(normalized).host
        return nil if uri_host.nil? || uri_host.empty?
        return nil unless TargetIntel.same_scope_host?(host || "", uri_host)

        normalized
      rescue
        nil
      end

      # An absolute http(s) link that points outside the target scope.
      def external_link(host : String?, href : String?) : String?
        return nil if href.nil?
        return nil unless href.starts_with?("http://") || href.starts_with?("https://")

        uri_host = URI.parse(href).host
        return nil if uri_host.nil? || uri_host.empty?
        return nil if TargetIntel.same_scope_host?(host || "", uri_host)

        href
      rescue
        nil
      end

      def target_host(target : String) : String?
        URI.parse(target).host
      rescue
        nil
      end

      # The scheme://host[:port] origin of a page, dropping a default port.
      def base_url_for(page_url : String) : String
        uri = URI.parse(page_url)
        scheme = uri.scheme || "http"
        host = uri.host || ""
        port = uri.port
        host = "#{host}:#{port}" if port && port != default_port(scheme)
        "#{scheme}://#{host}"
      end

      # True when the URL is an http(s) link to a `.xml`/`.xml.gz` path with a
      # host (a plausible sitemap document).
      def sitemap_candidate?(url : String) : Bool
        uri = URI.parse(url)
        host = uri.host
        path = uri.path.downcase
        http_scheme?(uri.scheme) && !(host.nil? || host.empty?) &&
          (path.ends_with?(".xml") || path.ends_with?(".xml.gz"))
      rescue
        false
      end

      # True when the URL is an http(s) link whose host shares the target scope.
      def same_scope_url?(url : String, target_host : String?) : Bool
        uri = URI.parse(url)
        host = uri.host
        return false unless http_scheme?(uri.scheme)
        return false if host.nil? || host.empty?

        TargetIntel.same_scope_host?(host, target_host || "")
      rescue
        false
      end

      # Security: target-controlled sitemap URLs stay as intel but cannot expand
      # fetch scope, so only in-scope sitemap candidates are kept for fetching.
      def scoped_sitemap_candidates(urls : Array(String), target_host : String?) : Array(String)
        urls.select { |url| sitemap_candidate?(url) && same_scope_url?(url, target_host) }
      end

      # De-duplicates (first-seen order, O(n) via a Set) and caps a link list.
      def cap_links(links : Array(String), limit : Int32) : Array(String)
        seen = Set(String).new
        capped = [] of String
        links.each do |link|
          break if capped.size >= limit

          capped << link if seen.add?(link)
        end
        capped
      end

      # Families whose bytes are never a document the crawler parses. A missing or
      # unfamiliar type still parses: live targets serve HTML as text/plain or
      # with no type at all, and the body caps bound the work either way. This is
      # about not building a tree out of a PNG, not about trusting the label.
      BINARY_TYPES = %w[image/ audio/ video/ font/ application/octet-stream application/pdf application/zip]

      def parseable_text?(content_type : String?) : Bool
        type = content_type.to_s.split(';', 2).first.strip.downcase
        return true if type.empty?

        BINARY_TYPES.none? { |family| type.starts_with?(family) }
      end

      # Security: custom headers can carry session cookies, so only the page's
      # own origin receives them; a sibling host in scope (a CDN, a status page)
      # is fetched without them. Cost: one origin compare per fetch.
      def origin_headers(url : String, page_url : String, headers : ::HTTP::Headers) : ::HTTP::Headers
        TargetIntel.same_origin?(url, page_url) ? headers : ::HTTP::Headers.new
      end

      private def http_scheme?(scheme : String?) : Bool
        scheme == "http" || scheme == "https"
      end

      private def default_port(scheme : String) : Int32
        scheme == "https" ? 443 : 80
      end
    end
  end
end
