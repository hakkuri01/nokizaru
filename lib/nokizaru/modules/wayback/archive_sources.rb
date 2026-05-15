# frozen_string_literal: true

require 'json'
require 'timeout'
require 'uri'
require_relative '../../keys'

module Nokizaru
  module Modules
    module Wayback
      # Bounded archive URL sources beyond Wayback CDX
      module ArchiveSources
        module_function

        COMMON_CRAWL_INDEX_URL = 'https://index.commoncrawl.org/collinfo.json'

        def archive_record(url, source, timestamp = nil)
          record = { 'url' => url.to_s, 'source' => source.to_s }
          record['timestamp'] = timestamp.to_s unless timestamp.to_s.empty?
          record
        end

        def filter_records(records, urls)
          allowed = Array(urls).to_h { |url| [url, true] }
          Array(records).select { |record| allowed[record['url']] }
        end

        def dedupe_records(records)
          seen = {}
          Array(records).each_with_object([]) do |record, out|
            url = record['url'].to_s
            next if url.empty? || seen[url]

            seen[url] = true
            out << record
          end
        end

        def fetch_commoncrawl_records(target, timeout_s, deadline_at: nil)
          timeout = Query.bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [] unless timeout.positive?

          Timeout.timeout(timeout) do
            index = latest_commoncrawl_index(timeout, deadline_at)
            index ? commoncrawl_index_records(index, target, timeout, deadline_at) : []
          end
        rescue Timeout::Error
          []
        end

        def latest_commoncrawl_index(timeout_s, deadline_at)
          response = HTTP.get(URI(COMMON_CRAWL_INDEX_URL), timeout_s: timeout_s, deadline_at: deadline_at)
          return nil unless Nokizaru::HTTPClient.status_code(response) == 200

          Array(JSON.parse(response.body)).find { |entry| entry['cdx-api'].to_s.start_with?('http') }
        rescue StandardError => e
          Log.write("[wayback] Common Crawl index exception = #{e}")
          nil
        end

        def commoncrawl_index_records(index, target, timeout_s, deadline_at)
          uri = URI(index['cdx-api'])
          uri.query = URI.encode_www_form(url: commoncrawl_target_pattern(target), output: 'json', fl: 'url,timestamp')
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at)
          return [] unless Nokizaru::HTTPClient.status_code(response) == 200

          parse_commoncrawl_lines(response.body)
        rescue StandardError => e
          Log.write("[wayback] Common Crawl fetch exception = #{e}")
          []
        end

        def commoncrawl_target_pattern(target)
          host = URI.parse(target.to_s).host.to_s.downcase
          host.empty? ? target.to_s : "*.#{host}/*"
        rescue StandardError
          target.to_s
        end

        def parse_commoncrawl_lines(body)
          body.to_s.each_line.filter_map do |line|
            item = JSON.parse(line)
            url = item['url'].to_s
            next if url.empty?

            archive_record(url, 'commoncrawl', item['timestamp'])
          rescue JSON::ParserError
            nil
          end
        end

        def fetch_virustotal_records(target, timeout_s, deadline_at: nil)
          key = Nokizaru::KeyStore.fetch('virustotal', env: 'NK_VT_KEY')
          return [] unless key

          timeout = Query.bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [] unless timeout.positive?

          Timeout.timeout(timeout) { virustotal_records(target, key, timeout, deadline_at) }
        rescue Timeout::Error
          []
        end

        def virustotal_records(target, key, timeout_s, deadline_at)
          host = URI.parse(target.to_s).host.to_s.downcase
          return [] if host.empty?

          uri = URI("https://www.virustotal.com/api/v3/domains/#{URI.encode_www_form_component(host)}/urls")
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, headers: { 'x-apikey' => key })
          return [] unless Nokizaru::HTTPClient.status_code(response) == 200

          parse_virustotal_urls(response.body)
        rescue StandardError => e
          Log.write("[wayback] VirusTotal URL fetch exception = #{e}")
          []
        end

        def parse_virustotal_urls(body)
          Array(JSON.parse(body)['data']).filter_map do |entry|
            url = entry.dig('attributes', 'url').to_s
            url.empty? ? nil : archive_record(url, 'virustotal')
          end
        rescue StandardError
          []
        end
      end
    end
  end
end
