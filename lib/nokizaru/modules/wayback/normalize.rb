# frozen_string_literal: true

require 'uri'
require 'public_suffix'

module Nokizaru
  module Modules
    module Wayback
      # URL normalization and filtering helpers
      module Normalize
        module_function

        LOW_SIGNAL_EXTENSIONS = %w[
          .png .jpg .jpeg .gif .webp .svg .ico .bmp .tif .tiff .avif
          .css .less .scss .sass .js .mjs .map .ts
          .woff .woff2 .ttf .otf .eot
          .pdf .zip .gz .bz2 .xz .7z .rar .tar .tgz
          .mp3 .wav .ogg .m4a .mp4 .webm .mov .avi .mkv
        ].freeze
        HIGH_SIGNAL_TOKENS = %w[
          admin login signin auth account dashboard api graphql oauth token
          config backup db database env passwd secrets private internal
          wp-admin wp-login xmlrpc wp-json server-status server-info
        ].freeze

        def fallback_urls_from_availability(avail_data)
          return [] unless avail_data.is_a?(Hash)

          closest = avail_data['closest']
          return [] unless closest.is_a?(Hash)

          url = closest['url'].to_s.strip
          return [] if url.empty?

          original = original_url_from_archive_snapshot(url)
          original.empty? ? [url] : [original]
        end

        def original_url_from_archive_snapshot(url)
          uri = URI.parse(url)
          return '' unless uri.host.to_s.include?('web.archive.org')

          match = uri.path.to_s.match(%r{/web/\d+(?:[a-z_]*)/(https?://.+)\z}i)
          return '' unless match

          URI.decode_www_form_component(match[1].to_s)
        rescue StandardError
          ''
        end

        def filter_urls(urls, target: nil)
          scope = target_scope(target)
          Array(urls)
            .map { |url| sanitize_url(url) }
            .reject(&:empty?)
            .select { |url| in_scope?(url, scope) }
            .reject { |url| low_signal_asset?(url) }
            .uniq
        end

        def rank_high_signal_urls(urls, limit: 250)
          Array(urls)
            .compact
            .uniq
            .map { |url| [url, score_url(url)] }
            .select { |(_, score)| score.positive? }
            .sort_by { |(url, score)| [-score, url.length] }
            .first(limit.to_i)
            .map(&:first)
        end

        def sanitize_url(url)
          cleaned = url.to_s.strip.sub(/["'`,;\])]+\z/, '')
          return '' if cleaned.empty?
          return '' if cleaned.include?(' ')
          return '' if cleaned.match?(/%[0-9A-Fa-f]?\z/)

          uri = URI.parse(cleaned)
          return '' unless uri.is_a?(URI::HTTP) && uri.host

          cleaned
        rescue StandardError
          ''
        end

        def target_scope(target)
          return nil if target.to_s.strip.empty?

          host = URI.parse(target).host.to_s.downcase
          return nil if host.empty?

          registrable_domain(host)
        rescue StandardError
          nil
        end

        def in_scope?(url, scope)
          return true if scope.nil?

          host = URI.parse(url).host.to_s.downcase
          return false if host.empty?

          registrable_domain(host) == scope
        rescue StandardError
          false
        end

        def registrable_domain(host)
          value = PublicSuffix.domain(host)
          labels = host.to_s.split('.').reject(&:empty?)
          normalized = value.to_s.downcase
          unless normalized.empty?
            return labels.last(2).join('.') if normalized == host.to_s.downcase && labels.length > 2

            return normalized
          end

          return host if labels.length < 2

          labels.last(2).join('.')
        rescue StandardError
          labels = host.to_s.split('.').reject(&:empty?)
          return host if labels.length < 2

          labels.last(2).join('.')
        end

        def low_signal_asset?(url)
          path = URI.parse(url).path.to_s.downcase
          return false if path.empty?

          LOW_SIGNAL_EXTENSIONS.any? { |ext| path.end_with?(ext) }
        rescue StandardError
          false
        end

        def score_url(url)
          uri = URI.parse(url)
          path = uri.path.to_s.downcase
          score = 0
          score += 4 if HIGH_SIGNAL_TOKENS.any? { |token| path.include?(token) }
          score += 2 if path.count('/') >= 2
          score += 1 unless uri.query.to_s.empty?
          score -= 3 if low_signal_asset?(url)
          score
        rescue StandardError
          0
        end
      end
    end
  end
end
