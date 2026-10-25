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
    # and retained membership sets. Only the ordered merge mutates this state.
    class SitemapState
      getter links : Array(String)
      getter sitemaps : Array(String)
      property pending : Array(String)
      getter target_host : String?
      getter page_url : String
      getter seen : Set(String)
      getter link_seen : Set(String)
      getter sitemap_seen : Set(String)

      def initialize(sitemap_links : Array(String), @page_url : String, budget : Budget)
        normalized = sitemap_links.map(&.strip)
        normalized.uniq!
        @target_host = UrlRules.target_host(@page_url)
        @links = [] of String
        @sitemaps = normalized.first(budget.max_sitemap_links)
        @pending = UrlRules.scoped_sitemap_candidates(normalized, @target_host).first(budget.max_sitemaps)
        @seen = Set(String).new
        @link_seen = Set(String).new
        @sitemap_seen = @sitemaps.to_set
      end
    end

    record SitemapDocument,
      links : Array(String) = [] of String,
      sitemaps : Array(String) = [] of String,
      pending : Array(String) = [] of String

    # Walks the sitemap graph breadth-first over a bounded fiber pool, following
    # `<sitemap><loc>` children in scope and collecting `<url><loc>` page URLs,
    # all under the live caps. Ports crawler/sitemaps.rb. Gzip (`.xml.gz`) bodies
    # are inflated with the inflated size capped (a small `.gz` can inflate
    # without bound). Complexity: at most `max_sitemaps` documents fetched, each
    # parsed once in O(bytes) capped at MAX_BYTES; extraction and merging append
    # capped unique prefixes, with O(1) membership checks and no merge lock.
    class Sitemaps
      def initialize(@fetcher : Fetcher, @request_headers : ::HTTP::Headers, @budget : Budget, @counts : Surface)
      end

      # Returns {urls_inside_sitemap, updated_sitemap_links}. On an exhausted
      # budget or empty queue it leaves the sitemap list untouched.
      def crawl(sitemap_links : Array(String), page_url : String) : {Array(String), Array(String)}
        @budget.apply(@counts)
        return {[] of String, sitemap_links} if @budget.exhausted?

        state = SitemapState.new(sitemap_links, page_url, @budget)
        return {[] of String, sitemap_links} if state.pending.empty?

        walk(state)
        {state.links, state.sitemaps.first(@budget.max_sitemap_links)}
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
        batch = [] of String
        state.pending.each do |url|
          break if batch.size >= remaining

          batch << url unless state.seen.includes?(url)
        end
        batch
      end

      private def crawl_batch(batch : Array(String), state : SitemapState) : Array(String)
        positions = Hash(String, Int32).new
        batch.each_with_index { |url, index| positions[url] = index }
        # ponytail: at most 200 capped document slots per level; stream ordered merges if caps grow
        documents = Array.new(batch.size) { SitemapDocument.new }
        Concurrency.each_concurrently(batch) do |sitemap_url, fetcher|
          next if @budget.exhausted?

          headers = UrlRules.origin_headers(sitemap_url, state.page_url, @request_headers)
          documents[positions[sitemap_url]] = parse_document(sitemap_url, headers, fetcher, state.target_host)
        end
        discovered = [] of String
        pending_seen = Set(String).new
        documents.each { |document| merge_batch(state, document, discovered, pending_seen) }
        discovered
      end

      private def merge_batch(state : SitemapState, document : SitemapDocument, discovered : Array(String), pending_seen : Set(String)) : Nil
        append_capped(state.links, document.links, state.link_seen, @budget.max_sitemap_urls)
        append_capped(state.sitemaps, document.sitemaps, state.sitemap_seen, @budget.max_sitemap_links)
        append_capped(discovered, document.pending, pending_seen, @budget.max_sitemaps)
      end

      private def append_capped(destination : Array(String), source : Array(String), seen : Set(String), cap : Int32) : Nil
        source.each do |url|
          break if destination.size >= cap

          destination << url if seen.add?(url)
        end
      end

      private def parse_document(sitemap_url : String, headers : ::HTTP::Headers, fetcher : Fetcher, target_host : String?) : SitemapDocument
        return SitemapDocument.new if @budget.exhausted?

        fetch = @fetcher.take_sitemap(sitemap_url) || fetcher.fetch_following(sitemap_url, headers)
        return SitemapDocument.new unless fetch.success?

        body = decode_body(fetch.result.try(&.body) || "", sitemap_url)
        return SitemapDocument.new if body.empty?

        doc = XML.parse(body)
        pages = xml_links(doc, "//*[local-name()='url']/*[local-name()='loc']", @budget.max_sitemap_urls) { true }
        child_xpath = "//*[local-name()='sitemap']/*[local-name()='loc']"
        children = xml_links(doc, child_xpath, @budget.max_sitemap_links) { |url| UrlRules.sitemap_candidate?(url) }
        pending = xml_links(doc, child_xpath, @budget.max_sitemaps) do |url|
          UrlRules.sitemap_candidate?(url) && UrlRules.same_scope_url?(url, target_host)
        end
        SitemapDocument.new(pages, children, pending)
      rescue
        SitemapDocument.new
      end

      private def xml_links(doc : XML::Node, xpath : String, cap : Int32, &accept : String -> Bool) : Array(String)
        links = [] of String
        seen = Set(String).new
        doc.xpath_nodes(xpath).each do |node|
          break if links.size >= cap

          url = node.text.strip
          next if url.empty? || !accept.call(url)

          links << url if seen.add?(url)
        end
        links
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
