# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Redirects
        private

        # Build a stable body fingerprint for generic wildcard pages with minor dynamic values
        def body_fingerprint(body)
          raw = body.to_s
          return nil if raw.empty?

          slice = if raw.bytesize <= 2048
                    raw
                  else
                    "#{raw.byteslice(0, 1024)}#{raw.byteslice(-1024, 1024)}"
                  end

          normalized = slice.downcase.gsub(/[a-f0-9]{8,}/i, '#').gsub(/\d+/, '#').gsub(/\s+/, ' ').strip
          return nil if normalized.empty?

          Zlib.crc32(normalized).to_s(16)
        end

        # Normalize content type so comparisons ignore charset variations
        def normalize_content_type(content_type)
          content_type.to_s.split(';', 2).first.to_s.strip.downcase
        end

        # Normalize location for wildcard redirect matching while ignoring dynamic query strings
        def normalize_location(location)
          value = location.to_s.strip
          return nil if value.empty?

          uri = URI.parse(value)
          path = uri.path.to_s
          path = '/' if path.empty?
          host = uri.host.to_s.downcase
          return path if host.empty?

          "#{host}#{path}"
        rescue URI::InvalidURIError
          value.split('?', 2).first
        end

        def normalize_target_base(target)
          value = target.to_s.strip
          return value if value.empty?

          value.end_with?('/') ? value.chomp('/') : value
        end

        def normalized_location_from_request(request_url, location_header)
          value = location_header.to_s.strip
          return nil if value.empty?

          resolved = if request_url.to_s.strip.empty?
                       value
                     else
                       Nokizaru::TargetIntel.resolve_location(request_url, value)
                     end

          normalize_location(resolved)
        end

        def redirect_signal_type(request_url, http_result)
          location_header = http_result.headers['location'].to_s
          return nil if location_header.strip.empty?

          resolved = Nokizaru::TargetIntel.resolve_location(request_url, location_header)
          return :cross_scope if cross_scope_redirect?(request_url, resolved)
          return :callback_like if callback_like_redirect?(location_header, resolved)

          pattern = redirect_pattern(request_url, location_header)
          return :auth_flow if pattern.to_s.start_with?('auth_entry:')

          nil
        rescue StandardError
          nil
        end

        def cross_scope_redirect?(request_url, resolved_location)
          req = URI.parse(request_url.to_s)
          loc = URI.parse(resolved_location.to_s)
          return false if req.host.to_s.empty? || loc.host.to_s.empty?

          !Nokizaru::TargetIntel.same_scope_host?(req.host, loc.host)
        rescue StandardError
          false
        end

        def callback_like_redirect?(location_header, resolved_location)
          value = [location_header, resolved_location].compact.join(' ').downcase
          return false if value.empty?

          callback_tokens.any? { |token| value.include?(token) }
        end

        def callback_tokens
          @callback_tokens ||= %w[callback redirect_uri return next continue destination dest oauth state code
                                  verifier].freeze
        end

        def push_redirect_example(examples, signal_type, status, request_url, http_result)
          return if examples.count { |entry| entry[:type].to_sym == signal_type.to_sym } >= 3

          location = http_result.headers['location'].to_s.strip
          return if location.empty?

          examples << {
            type: signal_type,
            status: status.to_i,
            request: summarize_redirect_url(request_url),
            location: summarize_redirect_url(location)
          }
        end

        def summarize_redirect_url(url)
          value = url.to_s.strip
          return value if value.length <= 80

          "#{value[0, 77]}..."
        end

        # Build a generic redirect pattern so path-preserving redirects can be recognized as one behavior class
        def redirect_pattern(request_url, location_header)
          req = URI.parse(request_url.to_s)
          resolved = Nokizaru::TargetIntel.resolve_location(request_url, location_header)
          loc = URI.parse(resolved)
          return nil unless Nokizaru::TargetIntel.same_scope_host?(req.host, loc.host)

          req_path = normalize_pattern_path(req.path)
          loc_path = normalize_pattern_path(loc.path)
          redirect_pattern_for_paths(req_path, loc_path, loc)
        rescue StandardError
          nil
        end

        def redirect_pattern_for_paths(req_path, loc_path, loc)
          scheme_host = "#{loc.scheme}:#{loc.host.to_s.downcase}"
          return "same_path:#{scheme_host}" if req_path == loc_path
          return "same_path_slash:#{scheme_host}" if same_path_slash?(req_path, loc_path)
          return "root:#{scheme_host}" if loc_path == '/'
          return "auth_entry:#{scheme_host}" if loc_path.start_with?('/login', '/signin', '/auth')

          "path_specific:#{scheme_host}:#{loc_path}"
        end

        def same_path_slash?(req_path, loc_path)
          "#{req_path}/" == loc_path
        end

        # Normalize path for redirect pattern comparisons while preserving root
        def normalize_pattern_path(path)
          value = path.to_s
          value = '/' if value.empty?
          return '/' if value == '/'

          value.chomp('/')
        end

        # Generic redirect patterns are likely anti-enumeration normalizers unless they diverge from baseline
        def generic_redirect_pattern?(pattern)
          pattern.start_with?('same_path:', 'same_path_slash:', 'root:', 'auth_entry:')
        end

        def redirect_status?(status)
          REDIRECT_STATUSES.include?(status.to_i)
        end

        # Apply tiny per-worker backoff on sustained errors to improve useful throughput under strict targets
        def error_backoff_s(error_streak, mode = nil)
          return 0.0 if mode.to_s == MODE_HOSTILE

          streak = error_streak.to_i
          return 0.0 if streak < 4

          [((streak - 3) * 0.01), 0.05].min
        end

        def extract_title(body)
          match = body.match(%r{<title[^>]*>(.*?)</title>}im)
          return nil unless match

          title = match[1].to_s.gsub(/\s+/, ' ').strip.downcase
          title.empty? ? nil : title
        end
      end
    end
  end
end
