# frozen_string_literal: true

require 'uri'

module Nokizaru
  module Modules
    module Wayback
      # URL normalization and filtering helpers
      module Normalize
        module_function

        def fallback_urls_from_availability(avail_data)
          return [] unless avail_data.is_a?(Hash)

          closest = avail_data['closest']
          return [] unless closest.is_a?(Hash)

          url = closest['url'].to_s.strip
          url.empty? ? [] : [url]
        end

        def filter_urls(urls)
          Array(urls).map { |url| sanitize_url(url) }.reject(&:empty?).uniq
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
      end
    end
  end
end
