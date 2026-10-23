require "uri"
require "digest/crc32"
require "./limits"
require "../target_intel"

module Nokizaru
  module DirRec
    # Pure field extraction and normalization over a response: the title, a stable
    # body fingerprint, the content type, and the redirect pattern used to cluster
    # path-preserving redirects. Ports the normalization and fingerprint helpers
    # from dirrec/redirects.rb. Each is one O(len) pass over a single value.
    #
    # ponytail: the fingerprint collapses the request URL's own path out of the
    # body before hashing so a wildcard page that echoes the path hashes stably.
    # The Ruby tool reflected many percent/HTML-escape variants of the request;
    # this port reflects the raw and decoded path only. The fingerprint is an
    # opaque hash compared only within a run (sample vs baseline), so a value that
    # is internally consistent but not byte-identical to Ruby's does not change
    # which paths are found. Upgrade: reflect the full escape-variant set.
    module Fields
      extend self

      LONG_HEX          = /[a-f0-9]{8,}/i
      DIGITS            = /\d+/
      WHITESPACE        = /\s+/
      TITLE             = /<title[^>]*>(.*?)<\/title>/im
      FINGERPRINT_SLICE = 2048
      FINGERPRINT_EDGE  = 1024

      def extract_title(body : String) : String?
        match = body.match(TITLE)
        return nil if match.nil?

        title = (match[1]? || "").gsub(WHITESPACE, " ").strip.downcase
        title.empty? ? nil : title
      end

      def body_fingerprint(body : String, request_url : String? = nil) : String?
        return nil if body.empty?

        slice = fingerprint_slice(body)
        normalized = normalize_request_reflections(slice.downcase, request_url)
          .gsub(LONG_HEX, "#").gsub(DIGITS, "#").gsub(WHITESPACE, " ").strip
        return nil if normalized.empty?

        Digest::CRC32.checksum(normalized).to_s(16)
      end

      def normalize_content_type(content_type : String?) : String
        content_type.to_s.split(';', 2).first.strip.downcase
      end

      def normalize_target_base(target : String) : String
        value = target.strip
        return value if value.empty?

        value.ends_with?("/") ? value.rchop("/") : value
      end

      def normalize_pattern_path(path : String) : String
        value = path.empty? ? "/" : path
        value == "/" ? "/" : value.rchop("/")
      end

      def redirect_status?(status : Int32) : Bool
        REDIRECT_STATUSES.includes?(status)
      end

      def generic_redirect_pattern?(pattern : String) : Bool
        pattern.starts_with?("same_path:") || pattern.starts_with?("same_path_slash:") ||
          pattern.starts_with?("reflected_path:") || pattern.starts_with?("root:") ||
          pattern.starts_with?("auth_entry:")
      end

      def normalize_location(location : String?) : String?
        value = location.to_s.strip
        return nil if value.empty?

        begin
          uri = URI.parse(value)
          path = uri.path.empty? ? "/" : uri.path
          host = (uri.host || "").downcase
          host.empty? ? path : "#{host}#{path}"
        rescue
          value.split('?', 2).first
        end
      end

      def normalized_location_from_request(request_url : String?, location_header : String?) : String?
        value = location_header.to_s.strip
        return nil if value.empty?

        resolved = request_url.to_s.strip.empty? ? value : TargetIntel.resolve_location(request_url.to_s, value)
        normalize_location(resolved)
      end

      # Builds a generic redirect pattern so path-preserving redirects read as one
      # behavior class (returns nil for an out-of-scope or unparseable target).
      def redirect_pattern(request_url : String?, location_header : String?) : String?
        req = URI.parse(request_url.to_s)
        resolved = TargetIntel.resolve_location(request_url.to_s, location_header.to_s)
        loc = URI.parse(resolved)
        return nil unless TargetIntel.same_scope_host?(req.host || "", loc.host || "")

        pattern_for_paths(normalize_pattern_path(req.path), normalize_pattern_path(loc.path), loc)
      rescue
        nil
      end

      private def pattern_for_paths(req_path : String, loc_path : String, loc : URI) : String
        scheme_host = "#{loc.scheme}:#{(loc.host || "").downcase}"
        return "same_path:#{scheme_host}" if req_path == loc_path
        return "same_path_slash:#{scheme_host}" if "#{req_path}/" == loc_path

        reflected = reflected_redirect_path(req_path, loc_path)
        return "reflected_path:#{scheme_host}:#{reflected}" unless reflected.nil?
        return "root:#{scheme_host}" if loc_path == "/"
        return "auth_entry:#{scheme_host}" if loc_path.starts_with?("/login") || loc_path.starts_with?("/signin") || loc_path.starts_with?("/auth")

        "path_specific:#{scheme_host}:#{loc_path}"
      end

      private def reflected_redirect_path(request_path : String, location_path : String) : String?
        return nil if request_path == "/"
        return nil if location_path.starts_with?("#{request_path}/")
        return nil unless reflected_path_segment?(location_path, request_path)

        location_path.sub(request_path, "{request}")
      end

      private def reflected_path_segment?(location_path : String, value : String) : Bool
        start = location_path.index(value)
        return false if start.nil?

        left_boundary = value.starts_with?("/") || start.zero? || location_path[start - 1] == '/'
        right_index = start + value.size
        left_boundary && (right_index == location_path.size || location_path[right_index] == '/')
      end

      private def fingerprint_slice(raw : String) : String
        return raw if raw.bytesize <= FINGERPRINT_SLICE

        "#{raw.byte_slice(0, FINGERPRINT_EDGE)}#{raw.byte_slice(raw.bytesize - FINGERPRINT_EDGE, FINGERPRINT_EDGE)}"
      end

      private def normalize_request_reflections(body : String, request_url : String?) : String
        return body if request_url.nil? || request_url.empty?

        result = body
        reflected_request_values(request_url).each { |value| result = result.gsub(value.downcase, "{request}") }
        result
      end

      private def reflected_request_values(request_url : String) : Array(String)
        uri = URI.parse(request_url)
        path = uri.path
        parts = [request_url, path]
        parts.concat(path.split('/'))
        decoded = parts.map { |part| decode(part) }
        values = (parts + decoded).select { |part| part.size >= 3 && part != "/" }
        values.uniq!
        values.sort_by! { |part| -part.size }
        values
      rescue
        [request_url].select { |part| part.size >= 3 }
      end

      private def decode(value : String) : String
        URI.decode(value)
      rescue
        value
      end
    end
  end
end
