require "json"

module Nokizaru
  module Crawler
    # The anchoring summary for the crawled target: the URL originally requested,
    # the one actually crawled, whether a re-anchor happened, and why. Matches the
    # Ruby result["target"] hash (the parity contract).
    struct Target
      include JSON::Serializable

      getter original : String
      property effective : String
      getter? reanchored : Bool
      getter reason : String
      getter reason_code : String

      def initialize(@original : String, @effective : String, @reanchored : Bool, @reason : String, @reason_code : String)
      end
    end

    # One phase of the main-page fetch (primary or fallback user-agent): the last
    # status seen, the last Location, the redirect hops taken, and the effective
    # URL reached. A class so the fetch state machine can update it in place as it
    # follows redirects (matching the Ruby profile mutation). status and location
    # stay null when absent (the key is always present).
    class FetchProfile
      include JSON::Serializable

      @[JSON::Field(emit_null: true)]
      property status : Int32?

      @[JSON::Field(emit_null: true)]
      property location : String?

      property hops : Int32
      property effective_url : String

      def initialize(@effective_url : String, @status : Int32? = nil, @location : String? = nil, @hops : Int32 = 0)
      end
    end

    # The two fetch phases: the primary user-agent attempt and, when a bot block
    # forced a retry under a browser user-agent, the fallback. fallback stays null
    # when it was never activated (the key is always present), as in Ruby.
    struct FetchProfiles
      include JSON::Serializable

      getter primary : FetchProfile

      @[JSON::Field(emit_null: true)]
      getter fallback : FetchProfile?

      def initialize(@primary : FetchProfile, @fallback : FetchProfile? = nil)
      end
    end

    # The crawl counts and derived URL sets. Every field is nilable and omitted
    # when unset, so a failed crawl (which never computes stats) serializes as an
    # empty object `{}`, exactly as the Ruby tool left result["stats"]. On a
    # successful crawl every field is populated. total_urls and high_signal_urls
    # are the full URL arrays, not counts, matching the Ruby stats hash.
    struct Stats
      include JSON::Serializable

      getter robots_count : Int32?
      getter sitemap_count : Int32?
      getter css_count : Int32?
      getter js_count : Int32?
      getter internal_count : Int32?
      getter external_count : Int32?
      getter images_count : Int32?
      getter sitemap_url_count : Int32?
      getter js_url_count : Int32?
      getter high_signal_count : Int32?
      getter total_unique : Int32?
      getter total_urls : Array(String)?
      getter high_signal_urls : Array(String)?
      getter crawl_mode : String?
      getter crawl_notes : Array(String)?

      def initialize(
        @robots_count : Int32? = nil,
        @sitemap_count : Int32? = nil,
        @css_count : Int32? = nil,
        @js_count : Int32? = nil,
        @internal_count : Int32? = nil,
        @external_count : Int32? = nil,
        @images_count : Int32? = nil,
        @sitemap_url_count : Int32? = nil,
        @js_url_count : Int32? = nil,
        @high_signal_count : Int32? = nil,
        @total_unique : Int32? = nil,
        @total_urls : Array(String)? = nil,
        @high_signal_urls : Array(String)? = nil,
        @crawl_mode : String? = nil,
        @crawl_notes : Array(String)? = nil,
      )
      end
    end

    # The crawler module result. The nine link buckets are always present (empty
    # on failure, matching Ruby's `[]`); stats is `{}` on failure and full on
    # success; the fetch envelope, high_signal_urls, and error fields are present
    # only when known. Field order follows the Ruby result hash so the serialized
    # shape lines up.
    #
    # ponytail: where Ruby explicitly set some early-failure keys to null
    # (`"fetch": null`), this port omits them instead. The meaningful output (the
    # discovered URLs and stats) is byte-faithful; the failure envelope is a
    # consistent typed shape. The parity harness compares successful crawls.
    class Result
      include JSON::Serializable

      property robots_links : Array(String) = [] of String
      property sitemap_links : Array(String) = [] of String
      property css_links : Array(String) = [] of String
      property js_links : Array(String) = [] of String
      property internal_links : Array(String) = [] of String
      property external_links : Array(String) = [] of String
      property images : Array(String) = [] of String
      property urls_inside_sitemap : Array(String) = [] of String
      property urls_inside_js : Array(String) = [] of String
      property stats : Stats = Stats.new
      property target : Target
      property status : String
      property fetch : FetchProfiles? = nil
      property active_user_agent : String? = nil
      property canonical_handoff : String? = nil
      property high_signal_urls : Array(String)? = nil
      property error : String? = nil
      property failure_reason : String? = nil
      property http_status : Int32? = nil
      property error_class : String? = nil

      def initialize(@target : Target, @status : String)
      end
    end
  end
end
