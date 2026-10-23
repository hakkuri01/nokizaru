require "xml"
require "compress/gzip"
require "io/memory"
require "./limits"
require "./url_rules"
require "./fetcher"
require "./budget"
require "./concurrency"
require "../http/client"

module Nokizaru
  module Crawler
    # The mutable state of one sitemap graph crawl: the accumulated page URLs, the
    # discovered sitemap documents, the pending queue, the seen set (cycle guard),
    # and a Mutex guarding the concurrent merges.
    class SitemapState
      property links : Array(String)
      property sitemaps : Array(String)
      property pending : Array(String)
      getter target_host : String?
      getter page_url : String
      getter seen : Set(String)
      getter mutex : Mutex

      def initialize(sitemap_links : Array(String), @page_url : String)
        normalized = sitemap_links.map(&.strip)
        normalized.uniq!
        @target_host = UrlRules.target_host(@page_url)
        @links = [] of String
        @sitemaps = normalized
        @pending = UrlRules.scoped_sitemap_candidates(normalized, @target_host)
        @seen = Set(String).new
        @mutex = Mutex.new
      end
    end

    # Walks the sitemap graph breadth-first over a bounded fiber pool, following
    # `<sitemap><loc>` children in scope and collecting `<url><loc>` page URLs,
    # all under the live caps. Ports crawler/sitemaps.rb. Gzip (`.xml.gz`) bodies
    # are inflated with the inflated size capped (a small `.gz` can inflate
    # without bound). Complexity: at most `max_sitemaps` documents fetched, each
    # parsed once in an O(bytes) pass capped at MAX_BYTES; lookups go through the
    # seen Set.
    class Sitemaps
      def initialize(@fetcher : Fetcher, @request_headers : ::HTTP::Headers, @budget : Budget, @counts : Surface)
      end

      # Returns {urls_inside_sitemap, updated_sitemap_links}. On an exhausted
      # budget or empty queue it leaves the sitemap list untouched.
      def crawl(sitemap_links : Array(String), page_url : String) : {Array(String), Array(String)}
        @budget.apply(@counts)
        return {[] of String, sitemap_links} if @budget.exhausted?

        state = SitemapState.new(sitemap_links, page_url)
        return {[] of String, sitemap_links} if state.pending.empty?

        walk(state)
        {state.links.uniq, UrlRules.cap_links(state.sitemaps, @budget.max_sitemap_links)}
      end

      private def walk(state : SitemapState) : Nil
        while !state.pending.empty? && state.seen.size < @budget.max_sitemaps
          @budget.apply(@counts)
          break if @budget.exhausted?
          break if state.links.size >= @budget.max_sitemap_urls

          batch = next_batch(state)
          break if batch.empty?

          batch.each { |url| state.seen << url }
          state.pending = crawl_batch(batch, state)
        end
      end

      private def next_batch(state : SitemapState) : Array(String)
        remaining = Math.max(@budget.max_sitemaps - state.seen.size, 0)
        fresh = state.pending.reject { |url| state.seen.includes?(url) }
        fresh.first(remaining)
      end

      private def crawl_batch(batch : Array(String), state : SitemapState) : Array(String)
        discovered = [] of String
        Concurrency.each_concurrently(batch) do |sitemap_url|
          next if @budget.exhausted?

          headers = UrlRules.origin_headers(sitemap_url, state.page_url, @request_headers)
          page_links, child_sitemaps = parse_document(sitemap_url, headers)
          state.mutex.synchronize { merge_batch(state, page_links, child_sitemaps, discovered) }
        end
        discovered.uniq
      end

      private def merge_batch(state : SitemapState, page_links : Array(String), child_sitemaps : Array(String), discovered : Array(String)) : Nil
        state.links = UrlRules.cap_links(state.links + page_links, @budget.max_sitemap_urls)
        state.sitemaps = UrlRules.cap_links(state.sitemaps + child_sitemaps, @budget.max_sitemap_links)
        discovered.concat(UrlRules.scoped_sitemap_candidates(child_sitemaps, state.target_host))
        capped = UrlRules.cap_links(discovered, @budget.max_sitemaps)
        discovered.clear
        discovered.concat(capped)
      end

      private def parse_document(sitemap_url : String, headers : ::HTTP::Headers) : {Array(String), Array(String)}
        return {[] of String, [] of String} if @budget.exhausted?

        fetch = @fetcher.fetch_following(sitemap_url, headers)
        return {[] of String, [] of String} unless fetch.success?

        body = decode_body(fetch.result.try(&.body) || "", sitemap_url)
        return {[] of String, [] of String} if body.empty?

        doc = XML.parse(body)
        page_locs = xml_links(doc, "//*[local-name()='url']/*[local-name()='loc']")
        child = xml_links(doc, "//*[local-name()='sitemap']/*[local-name()='loc']").select { |url| UrlRules.sitemap_candidate?(url) }
        {page_locs, child}
      rescue
        {[] of String, [] of String}
      end

      private def xml_links(doc : XML::Node, xpath : String) : Array(String)
        doc.xpath_nodes(xpath).map(&.text.strip).reject(&.empty?)
      end

      # The transport caps the compressed bytes; inflating through a capped read
      # caps the decompressed ones, so a gzip bomb cannot exhaust memory.
      private def decode_body(body : String, sitemap_url : String) : String
        return body if body.empty?
        return body unless gzip?(body)

        Compress::Gzip::Reader.open(IO::Memory.new(body.to_slice)) { |gz| read_capped(gz) }
      rescue
        ""
      end

      private def read_capped(io : IO) : String
        buffer = IO::Memory.new
        chunk = Bytes.new(16_384)
        total = 0
        while total < Http::BodyCap::MAX_BYTES
          read = io.read(chunk)
          break if read == 0

          take = Math.min(read, Http::BodyCap::MAX_BYTES - total)
          buffer.write(chunk[0, take])
          total += take
        end
        buffer.to_s
      end

      private def gzip?(body : String) : Bool
        bytes = body.to_slice
        bytes.size >= 2 && bytes[0] == 0x1F_u8 && bytes[1] == 0x8B_u8
      end
    end
  end
end
