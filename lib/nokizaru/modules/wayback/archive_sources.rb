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
          observation = {
            'source' => source.to_s,
            'timestamp' => timestamp.to_s
          }
          record = observation.merge('url' => url.to_s)
          record['sources'] = [source.to_s]
          record['observations'] = [observation]
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
            next if url.empty?

            if seen[url]
              merge_record!(seen[url], record)
              next
            end

            seen[url] = record
            out << record.dup
            seen[url] = out.last
          end
        end

        def merge_record!(existing, record)
          sources = Array(existing['sources']) | Array(record['sources'] || record['source'])
          fields = %w[source timestamp]
          incoming = record['observations'] || [record.slice(*fields)]
          observations = Array(existing['observations']) + Array(incoming)
          existing['sources'] = sources
          existing['observations'] = observations.uniq
        end

        def fetch_records(target, timeout_s, deadline_at: nil)
          common_crawl, common_crawl_health = fetch_commoncrawl_records(target, timeout_s, deadline_at: deadline_at)
          virustotal, virustotal_health = fetch_virustotal_records(target, timeout_s, deadline_at: deadline_at)
          [common_crawl + virustotal, {
            'common_crawl' => common_crawl_health,
            'virustotal' => virustotal_health
          }]
        end

        def fetch_commoncrawl_records(target, timeout_s, deadline_at: nil)
          timeout = Query.bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [[], commoncrawl_health('skipped', reason: 'deadline_exhausted')] unless timeout.positive?

          Timeout.timeout(timeout) do
            index, reason = latest_commoncrawl_index(timeout, deadline_at)
            next [[], commoncrawl_health(reason == 'timeout' ? 'timeout' : 'failed', reason: reason)] unless index

            commoncrawl_index_records(index, target, timeout, deadline_at)
          end
        rescue Timeout::Error
          [[], commoncrawl_health('timeout', reason: 'timeout')]
        end

        def latest_commoncrawl_index(timeout_s, deadline_at)
          timed_out = false
          response = HTTP.get(
            URI(COMMON_CRAWL_INDEX_URL),
            timeout_s: timeout_s,
            deadline_at: deadline_at,
            on_timeout: -> { timed_out = true }
          )
          return [nil, timed_out ? 'timeout' : 'request_failed'] unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return [nil, Query.response_reason(status)] unless status == 200

          index = Array(JSON.parse(response.body)).find { |entry| valid_commoncrawl_endpoint?(entry['cdx-api']) }
          [index, index ? nil : 'invalid_index']
        rescue Timeout::Error
          raise
        rescue StandardError => e
          Log.write("[wayback] Common Crawl index exception = #{e}")
          [nil, 'exception']
        end

        def commoncrawl_index_records(index, target, timeout_s, deadline_at)
          uri = URI(index['cdx-api'])
          uri.query = URI.encode_www_form(url: commoncrawl_target_pattern(target), output: 'json', fl: 'url,timestamp')
          timed_out = false
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, on_timeout: -> { timed_out = true })
          reason = timed_out ? 'timeout' : 'request_failed'
          return [[], commoncrawl_health(timed_out ? 'timeout' : 'failed', reason: reason)] unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return [[], commoncrawl_health('failed', reason: Query.response_reason(status))] unless status == 200

          records = parse_commoncrawl_lines(response.body)
          [records, commoncrawl_health(records.empty? ? 'empty' : 'found', records: records.length)]
        rescue Timeout::Error
          raise
        rescue StandardError => e
          Log.write("[wayback] Common Crawl fetch exception = #{e}")
          [[], commoncrawl_health('failed', reason: 'exception')]
        end

        def commoncrawl_health(status, records: 0, reason: nil)
          Query.source_health(status, records: records, reason: reason)
        end

        def commoncrawl_target_pattern(target)
          host = URI.parse(target.to_s).host.to_s.downcase
          host.empty? ? target.to_s : "*.#{host}/*"
        rescue StandardError
          target.to_s
        end

        def cdx_pattern(target, attempt)
          patterns = cdx_target_patterns(target)
          patterns.fetch(attempt[:pattern_index], patterns.first)
        end

        def cdx_target_pattern(target) = cdx_target_patterns(target).first

        def cdx_target_patterns(target)
          Query.availability_variants(target).flat_map do |variant|
            uri = URI.parse(variant.to_s)
            host = uri.host.to_s.downcase
            next ["#{variant}/*"] if host.empty?

            path = uri.path.to_s
            path = '' if path == '/'
            ["#{host}#{path}/*", "#{host}/", host]
          end.uniq
        rescue StandardError
          ["#{target}/*"]
        end

        def valid_commoncrawl_endpoint?(value)
          # Security: constrain provider-supplied URLs to prevent SSRF (official indexes use this host)
          uri = URI.parse(value.to_s)
          uri.is_a?(URI::HTTPS) && uri.host == 'index.commoncrawl.org' && uri.port == 443 && uri.userinfo.nil?
        rescue StandardError
          false
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
          return [[], Query.source_health('skipped', reason: 'missing_api_key')] unless key

          timeout = Query.bounded_timeout(timeout_s, deadline_at: deadline_at)
          return [[], Query.source_health('skipped', reason: 'deadline_exhausted')] unless timeout.positive?

          Timeout.timeout(timeout) { virustotal_records(target, key, timeout, deadline_at) }
        rescue Timeout::Error
          [[], Query.source_health('timeout', reason: 'timeout')]
        end

        def virustotal_records(target, key, timeout_s, deadline_at)
          host = URI.parse(target.to_s).host.to_s.downcase
          return [[], Query.source_health('failed', reason: 'invalid_target')] if host.empty?

          uri = URI("https://www.virustotal.com/api/v3/domains/#{URI.encode_www_form_component(host)}/urls")
          timed_out = false
          response = HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, headers: { 'x-apikey' => key },
                                   on_timeout: -> { timed_out = true })
          reason = timed_out ? 'timeout' : 'request_failed'
          return [[], Query.source_health(timed_out ? 'timeout' : 'failed', reason: reason)] unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return [[], Query.source_health('failed', reason: Query.response_reason(status))] unless status == 200

          records = parse_virustotal_urls(response.body)
          [records, Query.source_health(records.empty? ? 'empty' : 'found', records: records.length)]
        rescue Timeout::Error
          raise
        rescue StandardError => e
          Log.write("[wayback] VirusTotal URL fetch exception = #{e}")
          [[], Query.source_health('failed', reason: 'exception')]
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
