require "uri"
require "json"
require "../target_intel"

module Nokizaru
  module Wayback
    # The categorized high-signal URLs plus the parameter-name histogram, merged
    # flat into the Wayback payload. Field names match the Ruby triage hash.
    struct Triage
      include JSON::Serializable

      getter javascript_urls : Array(String)
      getter api_urls : Array(String)
      getter interesting_path_urls : Array(String)
      getter interesting_parameter_urls : Array(String)
      getter sensitive_file_urls : Array(String)
      getter review_urls : Array(String)
      getter parameter_counts : Hash(String, Int32)

      def initialize(
        @javascript_urls : Array(String),
        @api_urls : Array(String),
        @interesting_path_urls : Array(String),
        @interesting_parameter_urls : Array(String),
        @sensitive_file_urls : Array(String),
        @review_urls : Array(String),
        @parameter_counts : Hash(String, Int32),
      )
      end
    end

    # URL hygiene, scope filtering, and signal classification for the archived
    # URLs. Ports modules/wayback/normalize.rb. Every URL is from an untrusted
    # archive response, so each is validated (length, control chars, userinfo)
    # before use, and each classification is one O(len) pass over a single URL.
    module Normalize
      extend self

      MAX_URL_LENGTH = 8192
      CATEGORY_LIMIT =  250

      NOISE_EXTENSIONS = %w[
        .png .jpg .jpeg .gif .webp .svg .ico .bmp .tif .tiff .avif
        .css .less .scss .sass .woff .woff2 .ttf .otf .eot
        .mp3 .wav .ogg .m4a .mp4 .webm .mov .avi .mkv
      ]
      JAVASCRIPT_EXTENSIONS     = %w[.js .mjs .cjs .jsx .ts .tsx .map]
      API_SEGMENTS              = %w[api graphql rest rpc swagger openapi]
      INTERESTING_PATH_SEGMENTS = %w[
        admin login signin sign-in auth account dashboard oauth token config backup database
        private internal wp-admin wp-login xmlrpc wp-json server-status server-info
      ]
      INTERESTING_PARAMETERS = %w[
        admin api_key apikey callback cmd continue debug file id key next path redirect return return_to
        token url user username
      ]
      SENSITIVE_FILENAMES = %w[
        .env .gitignore .htaccess .htpasswd docker-compose.yml docker-compose.yaml id_rsa id_dsa
        package-lock.json composer.lock web.config wp-config.php
      ]
      SENSITIVE_SUFFIXES = %w[
        .bak .backup .conf .config .db .dump .ini .key .log .old .pem .properties .secret .sql .sqlite
        .swp .tar .tgz .zip .gz .bz2 .xz .7z .rar
      ]

      # Rejects a trailing incomplete percent-escape or a lone trailing percent.
      INCOMPLETE_ESCAPE = /%[0-9A-Fa-f]?\z/
      # Rejects a control character or a literal space anywhere in the raw URL.
      RAW_CONTROL = /[[:cntrl:] ]/
      # Any control character in a decoded component.
      DECODED_CONTROL = /[[:cntrl:]]/
      # A userinfo authority (user[:pass]@host) the archive must never carry.
      USERINFO_AUTHORITY = /\Ahttps?:\/\/[^\/]*@/i
      # Pulls the original URL back out of an archive replay URL.
      ARCHIVE_REPLAY = /\Ahttps?:\/\/web\.archive\.org\/web\/\d+(?:[a-z_]*)\/(https?:\/\/.+)\z/i
      # A versioned API segment (v1, v2, ...).
      API_VERSION = /\Av\d+\z/
      # A config/credentials/secrets/settings data file.
      SENSITIVE_CONFIG = /\A(?:config|credentials|secrets?|settings)\.(?:json|ya?ml|xml)\z/

      # One sanitized URL and its parsed URI, or nil when the raw URL fails
      # validation.
      record SanitizedUrl, url : String, uri : URI

      def original_url_from_archive_snapshot(url : String) : String
        uri = URI.parse(url)
        scheme = uri.scheme
        return "" unless (scheme == "http" || scheme == "https") && uri.host == "web.archive.org" && uri.user.nil?

        match = url.match(ARCHIVE_REPLAY)
        match ? (match[1]? || "") : ""
      rescue
        ""
      end

      # Keeps the in-scope, non-duplicate URLs. With exact_host the host must
      # equal the target host; otherwise same registrable domain. Noise paths are
      # dropped unless include_noise. O(n) over the URL list.
      def filter_urls(urls : Array(String), target : String?, include_noise : Bool, exact_host : Bool) : Array(String)
        scope = target_scope(target)
        host_scope = exact_host ? target_host(target) : nil
        seen = Set(String).new
        filtered = [] of String
        urls.each do |url|
          record = sanitized_url_record(url)
          next if record.nil?
          next unless in_scope?(record, scope, host_scope)
          next if !include_noise && noise_path?(record.uri.path)
          next unless seen.add?(record.url)

          filtered << record.url
        end
        filtered
      end

      def signal_labels(url : String) : Array(String)
        record = sanitized_url_record(url)
        return [] of String if record.nil?

        uri = record.uri
        segments = decoded_segments(uri.path)
        labels = [] of String
        labels << "javascript" if javascript_path?(uri.path)
        labels << "api" if api_path?(segments)
        labels << "interesting_path" if interesting_path?(segments)
        labels << "interesting_parameter" unless relevant_parameters(uri.query).empty?
        labels << "sensitive_file" if sensitive_file?(segments.last?)
        labels
      end

      def noise_url?(url : String) : Bool
        record = sanitized_url_record(url)
        record.nil? || noise_path?(record.uri.path)
      end

      # Buckets the URLs into the signal categories, ranks review_urls by how many
      # categories each hit (then first-seen order), and counts interesting
      # parameters. O(n) to classify; O(k log k) to rank the matched set.
      def triage(urls : Array(String), limit : Int32 = CATEGORY_LIMIT) : Triage
        categories = empty_categories
        parameter_counts = Hash(String, Int32).new(0)
        order = {} of String => Int32
        urls.each_with_index do |url, index|
          record = sanitized_url_record(url)
          next if record.nil?

          order[url] ||= index
          classify_url(categories, url, record.uri, limit).each { |name| parameter_counts[name] += 1 }
        end
        build_triage(categories, parameter_counts, order, limit)
      end

      def sanitized_url_record(url : String) : SanitizedUrl?
        cleaned = url.strip
        return nil unless valid_raw_url?(cleaned)
        return nil if cleaned.matches?(USERINFO_AUTHORITY)

        uri = URI.parse(cleaned)
        scheme = uri.scheme
        host = uri.host
        return nil unless scheme == "http" || scheme == "https"
        return nil if host.nil? || host.empty?
        return nil unless uri.user.nil?
        return nil if decoded_control_character?(uri)

        SanitizedUrl.new(cleaned, uri)
      rescue
        nil
      end

      private def build_triage(categories : Hash(String, Array(String)), parameter_counts : Hash(String, Int32), order : Hash(String, Int32), limit : Int32) : Triage
        counts = Hash(String, Int32).new(0)
        categories.each_value { |urls| urls.each { |url| counts[url] += 1 } }
        review = counts.keys.sort_by! { |url| {-counts[url], order[url]? || 0} }.first(limit)
        Triage.new(
          javascript_urls: categories["javascript_urls"],
          api_urls: categories["api_urls"],
          interesting_path_urls: categories["interesting_path_urls"],
          interesting_parameter_urls: categories["interesting_parameter_urls"],
          sensitive_file_urls: categories["sensitive_file_urls"],
          review_urls: review,
          parameter_counts: sorted_counts(parameter_counts),
        )
      end

      private def empty_categories : Hash(String, Array(String))
        {
          "javascript_urls"            => [] of String,
          "api_urls"                   => [] of String,
          "interesting_path_urls"      => [] of String,
          "interesting_parameter_urls" => [] of String,
          "sensitive_file_urls"        => [] of String,
        }
      end

      private def classify_url(categories : Hash(String, Array(String)), url : String, uri : URI, limit : Int32) : Array(String)
        segments = decoded_segments(uri.path)
        add_category(categories, "javascript_urls", url, javascript_path?(uri.path), limit)
        add_category(categories, "api_urls", url, api_path?(segments), limit)
        add_category(categories, "interesting_path_urls", url, interesting_path?(segments), limit)
        parameters = relevant_parameters(uri.query)
        add_category(categories, "interesting_parameter_urls", url, !parameters.empty?, limit)
        add_category(categories, "sensitive_file_urls", url, sensitive_file?(segments.last?), limit)
        parameters
      end

      private def add_category(categories : Hash(String, Array(String)), category : String, url : String, matched : Bool, limit : Int32) : Nil
        bucket = categories[category]
        bucket << url if matched && bucket.size < limit
      end

      private def sorted_counts(counts : Hash(String, Int32)) : Hash(String, Int32)
        sorted = {} of String => Int32
        counts.keys.sort!.each { |name| sorted[name] = counts[name] }
        sorted
      end

      private def valid_raw_url?(url : String) : Bool
        !url.empty? && url.bytesize <= MAX_URL_LENGTH &&
          !url.matches?(RAW_CONTROL) && !url.matches?(INCOMPLETE_ESCAPE)
      end

      private def decoded_control_character?(uri : URI) : Bool
        {uri.path, uri.query}.any? do |part|
          next false if part.nil?

          URI.decode(part).matches?(DECODED_CONTROL)
        end
      rescue
        true
      end

      private def target_scope(target : String?) : String?
        return nil if target.nil? || target.strip.empty?

        host = target_host(target)
        host.empty? ? nil : TargetIntel.registrable_domain(host)
      rescue
        nil
      end

      private def target_host(target : String?) : String
        return "" if target.nil?

        (URI.parse(target).host || "").downcase.rchop(".")
      rescue
        ""
      end

      private def in_scope?(record : SanitizedUrl, scope : String?, host_scope : String?) : Bool
        host = (record.uri.host || "").downcase
        unless host_scope.nil? || host_scope.empty?
          return host.rchop(".") == host_scope
        end
        return true if scope.nil?
        return false if host.empty?

        TargetIntel.registrable_domain(host) == scope
      rescue
        false
      end

      private def noise_path?(path : String) : Bool
        value = path.downcase
        NOISE_EXTENSIONS.any? { |ext| value.ends_with?(ext) }
      end

      private def decoded_segments(path : String) : Array(String)
        path.split('/').compact_map do |segment|
          decoded = URI.decode(segment).downcase
          decoded.empty? ? nil : decoded
        rescue
          nil
        end
      end

      private def javascript_path?(path : String) : Bool
        value = path.downcase
        JAVASCRIPT_EXTENSIONS.any? { |ext| value.ends_with?(ext) }
      end

      private def api_path?(segments : Array(String)) : Bool
        segments.any? { |segment| API_SEGMENTS.includes?(segment) || segment.matches?(API_VERSION) }
      end

      private def interesting_path?(segments : Array(String)) : Bool
        segments.any? { |segment| INTERESTING_PATH_SEGMENTS.includes?(segment) }
      end

      private def relevant_parameters(query : String?) : Array(String)
        return [] of String if query.nil? || query.empty?

        names = [] of String
        URI::Params.parse(query).each do |name, _value|
          normalized = name.downcase
          names << normalized if INTERESTING_PARAMETERS.includes?(normalized)
        end
        names
      rescue
        [] of String
      end

      private def sensitive_file?(filename : String?) : Bool
        return false if filename.nil?

        value = filename.downcase
        SENSITIVE_FILENAMES.includes?(value) ||
          SENSITIVE_SUFFIXES.any? { |suffix| value.ends_with?(suffix) } ||
          value.matches?(SENSITIVE_CONFIG)
      end
    end
  end
end
