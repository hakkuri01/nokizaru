# frozen_string_literal: true

require 'public_suffix'
require 'uri'

module Nokizaru
  module Modules
    module Crawler
      # URL normalization and scope helpers for link extraction
      module LinkSupport
        private

        def internal_link(target, host, href)
          normalized = url_filter(target, href)
          return nil unless normalized

          uri = URI(normalized)
          return nil unless uri.host
          return nil if host && PublicSuffix.domain(uri.host) != host

          normalized
        rescue StandardError
          nil
        end

        def external_link(host, href)
          return nil unless href&.start_with?('http://', 'https://')

          uri = URI(href)
          return nil unless uri.host
          return nil if host && PublicSuffix.domain(uri.host) == host

          href
        rescue StandardError
          nil
        end

        def target_public_suffix_domain(target)
          PublicSuffix.domain(URI(target).host)
        rescue StandardError
          nil
        end

        def url_filter(target, link)
          return nil if link.to_s.empty?
          return nil if link.start_with?('#', 'javascript:', 'mailto:')

          base = target.end_with?('/') ? target : "#{target}/"
          URI.join(base, link).to_s
        rescue StandardError
          nil
        end
      end
    end
  end
end
