# frozen_string_literal: true

require 'uri'
require 'public_suffix'

module Nokizaru
  module Modules
    module Wayback
      module Normalize
        module_function

        MAX_URL_LENGTH = 8192
        CATEGORY_LIMIT = 250
        NOISE_EXTENSIONS = %w[
          .png .jpg .jpeg .gif .webp .svg .ico .bmp .tif .tiff .avif
          .css .less .scss .sass .woff .woff2 .ttf .otf .eot
          .mp3 .wav .ogg .m4a .mp4 .webm .mov .avi .mkv
        ].freeze
        JAVASCRIPT_EXTENSIONS = %w[.js .mjs .cjs .jsx .ts .tsx .map].freeze
        API_SEGMENTS = %w[api graphql rest rpc swagger openapi].freeze
        INTERESTING_PATH_SEGMENTS = %w[
          admin login signin sign-in auth account dashboard oauth token config backup database
          private internal wp-admin wp-login xmlrpc wp-json server-status server-info
        ].freeze
        INTERESTING_PARAMETERS = %w[
          admin api_key apikey callback cmd continue debug file id key next path redirect return return_to
          token url user username
        ].freeze
        SENSITIVE_FILENAMES = %w[
          .env .gitignore .htaccess .htpasswd docker-compose.yml docker-compose.yaml id_rsa id_dsa
          package-lock.json composer.lock web.config wp-config.php
        ].freeze
        SENSITIVE_SUFFIXES = %w[
          .bak .backup .conf .config .db .dump .ini .key .log .old .pem .properties .secret .sql .sqlite
          .swp .tar .tgz .zip .gz .bz2 .xz .7z .rar
        ].freeze
        def fallback_urls_from_availability(avail_data)
          return [] unless avail_data.is_a?(Hash)

          closest = avail_data['closest']
          return [] unless closest.is_a?(Hash)

          original = original_url_from_archive_snapshot(closest['url'].to_s.strip)
          return [] unless sanitized_url_record(original)

          meaningful_archive_fallback?(original) ? [original] : []
        end

        def meaningful_archive_fallback?(url)
          uri = sanitized_url_record(url)&.fetch(:uri, nil)
          uri && (!(uri.path.to_s.empty? || uri.path == '/') || !uri.query.to_s.empty?)
        end

        def original_url_from_archive_snapshot(url)
          archive = URI.parse(url.to_s)
          return '' unless archive.is_a?(URI::HTTP) && archive.host == 'web.archive.org' && archive.userinfo.nil?

          match = url.to_s.match(%r{\Ahttps?://web\.archive\.org/web/\d+(?:[a-z_]*)/(https?://.+)\z}i)
          match ? match[1] : ''
        rescue StandardError
          ''
        end

        def filter_urls(urls, target: nil)
          scope = target_scope(target)
          domain_cache = {}
          seen = {}
          Array(urls).each_with_object([]) do |url, filtered|
            record = sanitized_url_record(url)
            next unless record && in_scope_record?(record, scope, domain_cache)
            next if noise_path?(record[:uri].path) || seen[record[:url]]

            seen[record[:url]] = true
            filtered << record[:url]
            break if filtered.length >= Wayback::MAX_URLS
          end
        end

        def triage(urls, limit: CATEGORY_LIMIT)
          categories = {
            'javascript_urls' => [], 'api_urls' => [], 'interesting_path_urls' => [],
            'interesting_parameter_urls' => [], 'sensitive_file_urls' => []
          }
          parameter_counts = Hash.new(0)
          order = {}

          Array(urls).each_with_index do |url, index|
            record = sanitized_url_record(url)
            next unless record

            order[url] ||= index
            parameters = classify_url(categories, url, record[:uri], limit)
            parameters.uniq.each { |name| parameter_counts[name] += 1 }
          end

          labels = categories.values.flatten.tally
          review = labels.keys.sort_by { |url| [-labels[url], order.fetch(url)] }.first(limit)
          categories.merge('review_urls' => review, 'parameter_counts' => parameter_counts.sort.to_h)
        end

        def rank_high_signal_urls(urls, limit: CATEGORY_LIMIT)
          triage(urls, limit: limit)['review_urls']
        end

        def sanitized_url_record(url)
          cleaned = url.to_s.strip
          return nil unless valid_raw_url?(cleaned)

          uri = URI.parse(cleaned)
          return nil unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil?
          return nil if decoded_control_character?(uri)

          { url: cleaned, uri: uri }
        rescue StandardError
          nil
        end

        def valid_raw_url?(url)
          !url.empty? && url.bytesize <= MAX_URL_LENGTH && !url.match?(/[[:cntrl:] ]/) &&
            !url.match?(/%[0-9A-Fa-f]?\z/)
        end

        def decoded_control_character?(uri)
          [uri.path, uri.query].compact.any? do |part|
            URI::DEFAULT_PARSER.unescape(part).match?(/[[:cntrl:]]/)
          end
        rescue ArgumentError
          true
        end

        def target_scope(target)
          return nil if target.to_s.strip.empty?

          host = URI.parse(target).host.to_s.downcase
          host.empty? ? nil : registrable_domain(host)
        rescue StandardError
          nil
        end

        def in_scope_record?(record, scope, domain_cache)
          return true if scope.nil?

          host = record[:uri].host.to_s.downcase
          return false if host.empty?

          domain_cache[host] ||= registrable_domain(host)
          domain_cache[host] == scope
        rescue StandardError
          false
        end

        def registrable_domain(host)
          value = PublicSuffix.domain(host)
          labels = host.to_s.split('.').reject(&:empty?)
          normalized = value.to_s.downcase
          return labels.last(2).join('.') if normalized == host.to_s.downcase && labels.length > 2
          return normalized unless normalized.empty?

          labels.length < 2 ? host : labels.last(2).join('.')
        rescue StandardError
          labels = host.to_s.split('.').reject(&:empty?)
          labels.length < 2 ? host : labels.last(2).join('.')
        end

        def noise_path?(path)
          value = path.to_s.downcase
          NOISE_EXTENSIONS.any? { |ext| value.end_with?(ext) }
        end

        def decoded_segments(path)
          path.to_s.split('/').filter_map do |segment|
            decoded = URI.decode_www_form_component(segment).downcase
            decoded unless decoded.empty?
          rescue ArgumentError
            nil
          end
        end

        def javascript_path?(path)
          value = path.to_s.downcase
          JAVASCRIPT_EXTENSIONS.any? { |ext| value.end_with?(ext) }
        end

        def api_path?(segments)
          segments.any? { |segment| API_SEGMENTS.include?(segment) || segment.match?(/\Av\d+\z/) }
        end

        def interesting_path?(segments)
          segments.any? { |segment| INTERESTING_PATH_SEGMENTS.include?(segment) }
        end

        def relevant_parameters(query)
          URI.decode_www_form(query.to_s).filter_map do |name, _value|
            normalized = name.to_s.downcase
            normalized if INTERESTING_PARAMETERS.include?(normalized)
          end
        rescue ArgumentError
          []
        end

        def sensitive_file?(filename)
          value = filename.to_s.downcase
          SENSITIVE_FILENAMES.include?(value) || SENSITIVE_SUFFIXES.any? { |suffix| value.end_with?(suffix) } ||
            value.match?(/\A(?:config|credentials|secrets?|settings)\.(?:json|ya?ml|xml)\z/)
        end

        def classify_url(categories, url, uri, limit)
          segments = decoded_segments(uri.path)
          add_category(categories, 'javascript_urls', url, javascript_path?(uri.path), limit)
          add_category(categories, 'api_urls', url, api_path?(segments), limit)
          add_category(categories, 'interesting_path_urls', url, interesting_path?(segments), limit)
          parameters = relevant_parameters(uri.query)
          add_category(categories, 'interesting_parameter_urls', url, parameters.any?, limit)
          add_category(categories, 'sensitive_file_urls', url, sensitive_file?(segments.last), limit)
          parameters
        end

        def add_category(categories, category, url, matched, limit)
          categories[category] << url if matched && categories[category].length < limit.to_i
        end
      end
    end
  end
end
