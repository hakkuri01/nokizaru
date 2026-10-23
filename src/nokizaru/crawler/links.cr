require "xml"
require "./limits"
require "./url_rules"
require "./fetcher"
require "./budget"

module Nokizaru
  module Crawler
    # The link buckets extracted from the landing page plus robots.txt and the
    # sitemap seed.
    struct PageLinks
      getter robots_links : Array(String)
      getter sitemap_links : Array(String)
      getter css_links : Array(String)
      getter js_links : Array(String)
      getter internal_links : Array(String)
      getter external_links : Array(String)
      getter images : Array(String)

      def initialize(
        @robots_links : Array(String),
        @sitemap_links : Array(String),
        @css_links : Array(String),
        @js_links : Array(String),
        @internal_links : Array(String),
        @external_links : Array(String),
        @images : Array(String),
      )
      end
    end

    # Extracts links from the parsed landing page and from robots.txt, and seeds
    # the sitemap list. Ports crawler/links.rb. The document is parsed once by the
    # engine and queried here; each extraction is one O(nodes) pass over the tree
    # followed by an O(n) cap, so nothing grows with the response beyond the caps.
    class Links
      def initialize(@fetcher : Fetcher, @request_headers : ::HTTP::Headers, @budget : Budget)
      end

      def extract(doc : XML::Node, page_url : String, base_url : String) : PageLinks
        robots_links, discovered = robots("#{base_url}/robots.txt", base_url)
        PageLinks.new(
          robots_links: robots_links,
          sitemap_links: sitemap("#{base_url}/sitemap.xml", discovered),
          css_links: collect(doc, "//link[@rel='stylesheet']", "href", page_url, MAX_RESOURCE_LINKS),
          js_links: collect(doc, "//script[@src]", "src", page_url, MAX_RESOURCE_LINKS),
          internal_links: internal_links(page_url, doc),
          external_links: external_links(page_url, doc),
          images: collect(doc, "//img[@src]", "src", page_url, MAX_IMAGE_LINKS),
        )
      end

      private def robots(url : String, base_url : String) : {Array(String), Array(String)}
        fetch = @fetcher.fetch_following(url, @request_headers)
        return {[] of String, [] of String} unless fetch.success?

        body = fetch.result.try(&.body) || ""
        parse_robots_body(body, base_url)
      end

      private def parse_robots_body(body : String, base_url : String) : {Array(String), Array(String)}
        links = [] of String
        sitemaps = [] of String
        body.each_line do |line|
          directive = parse_robots_line(line, base_url)
          next if directive.nil?

          url, sitemap = directive
          links << url if url
          sitemaps << sitemap if sitemap
        end
        {UrlRules.cap_links(links, MAX_ROBOTS_LINKS), UrlRules.cap_links(sitemaps, MAX_SITEMAP_LINKS)}
      end

      private def parse_robots_line(line : String, base_url : String) : {String?, String?}?
        match = line.match(/\A\s*(Disallow|Allow|Sitemap)\s*:\s*(\S.*?)\s*\z/i)
        return nil if match.nil?

        directive = match[1]
        url = UrlRules.url_filter(base_url, match[2])
        sitemap = directive.compare("Sitemap", case_insensitive: true) == 0 ? url : nil
        {url, sitemap}
      end

      private def sitemap(url : String, discovered : Array(String)) : Array(String)
        links = UrlRules.cap_links(discovered, @budget.max_sitemap_links)
        fetch = @fetcher.fetch_following(url, @request_headers)
        links << fetch.effective_url if fetch.success?
        UrlRules.cap_links(links, @budget.max_sitemap_links)
      end

      private def collect(doc : XML::Node, xpath : String, attr : String, target : String, limit : Int32) : Array(String)
        urls = doc.xpath_nodes(xpath).compact_map { |node| UrlRules.url_filter(target, node[attr]?) }
        UrlRules.cap_links(urls, limit)
      end

      private def internal_links(page_url : String, doc : XML::Node) : Array(String)
        host = UrlRules.target_host(page_url)
        urls = doc.xpath_nodes("//a[@href]").compact_map { |node| UrlRules.internal_link(page_url, host, node["href"]?) }
        UrlRules.cap_links(urls, MAX_INTERNAL_LINKS)
      end

      private def external_links(page_url : String, doc : XML::Node) : Array(String)
        host = UrlRules.target_host(page_url)
        urls = doc.xpath_nodes("//a[@href]").compact_map { |node| UrlRules.external_link(host, node["href"]?) }
        UrlRules.cap_links(urls, MAX_EXTERNAL_LINKS)
      end
    end
  end
end
