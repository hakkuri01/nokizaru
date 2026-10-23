# frozen_string_literal: true

module Nokizaru
  module Modules
    module Wayback
      # Strict CDX request and response boundary
      module CDX
        module_function

        FIELDS = %w[timestamp original mimetype statuscode digest].freeze
        FIELD_LIMITS = {
          'timestamp' => 14, 'original' => Normalize::MAX_URL_LENGTH,
          'mimetype' => 256, 'statuscode' => 16, 'digest' => 256
        }.freeze
        PAGE_SIZE = 1000
        MAX_BODY_BYTES = 8 * 1024 * 1024
        MAX_RESUME_KEY_BYTES = 4096

        def build_payload(target, collapse: nil, from: nil, to: nil)
          host = URI.parse(target.to_s).host.to_s.downcase.delete_suffix('.')
          raise ArgumentError, 'Wayback target must include a hostname' if host.empty?

          payload = {
            'url' => "#{host}/", 'matchType' => 'host', 'output' => 'json', 'fl' => FIELDS.join(','),
            'filter' => exact_original_filter(host), 'limit' => PAGE_SIZE.to_s, 'showResumeKey' => 'true'
          }
          payload['collapse'] = collapse if collapse
          payload['from'] = from if from
          payload['to'] = to if to
          payload
        rescue URI::InvalidURIError
          raise ArgumentError, 'Wayback target must include a hostname'
        end

        def exact_original_filter(host)
          "original:(?i)^https?://#{Regexp.escape(host)}(?::[0-9]+)?(?:/|$)"
        end

        def fetch_page(payload, timeout_s, deadline_at: nil)
          uri = URI(Wayback::CDX_URL)
          uri.query = URI.encode_www_form(payload)
          timed_out = false
          response = Timeout.timeout(timeout_s) do
            HTTP.get(uri, timeout_s: timeout_s, deadline_at: deadline_at, on_timeout: -> { timed_out = true })
          end
          return [[], nil, timed_out ? 'timeout' : 'request_failed'] unless response

          status = Nokizaru::HTTPClient.status_code(response)
          return [[], nil, Query.response_reason(status)] unless status == 200
          return [[], nil, 'response_too_large'] if oversized_response?(response)

          parse_page(response.body)
        rescue Timeout::Error
          [[], nil, 'timeout']
        rescue JSON::ParserError => e
          Log.write("[wayback] CDX JSON parse exception = #{e}")
          [[], nil, 'invalid_response']
        rescue StandardError => e
          Log.write("[wayback] CDX fetch exception = #{e}")
          [[], nil, 'exception']
        end

        def oversized_response?(response)
          declared = Integer(Nokizaru::HTTPClient.header_value(response, 'Content-Length'), exception: false)
          body_size = response.body.respond_to?(:bytesize) ? response.body.bytesize : response.body.to_s.bytesize
          (declared && declared > MAX_BODY_BYTES) || body_size > MAX_BODY_BYTES
        end

        def parse_page(body)
          value = body.to_s
          raise JSON::ParserError, 'CDX response exceeds byte limit' if value.bytesize > MAX_BODY_BYTES

          rows = JSON.parse(value)
          raise JSON::ParserError, 'CDX response is not an array' unless rows.is_a?(Array)

          indexes = indexes_for(rows.shift)
          parse_rows(rows, indexes)
        end

        def indexes_for(header)
          raise JSON::ParserError, 'CDX response header is invalid' unless header.is_a?(Array)
          unless FIELDS.all? { |field| header.count(field) == 1 }
            raise JSON::ParserError, 'CDX response fields are incomplete or duplicated'
          end

          FIELDS.to_h { |field| [field, header.index(field)] }
        end

        def parse_rows(rows, indexes)
          parsed = []
          resume_key = nil
          separator_seen = false
          rows.each_with_index do |row, index|
            raise JSON::ParserError, 'CDX row is not an array' unless row.is_a?(Array)

            if row.empty?
              separator_seen = true
              next
            end
            if row.length == 1
              resume_key = parse_resume_key(row, separator_seen, index == rows.length - 1)
              next
            end
            raise JSON::ParserError, 'CDX data follows resume separator' if separator_seen
            raise JSON::ParserError, 'CDX response exceeds page limit' if parsed.length >= PAGE_SIZE

            parsed << parse_row(row, indexes)
          end
          validate_separator!(separator_seen, resume_key)
          [parsed, resume_key, nil]
        end

        def validate_separator!(separator_seen, resume_key)
          raise JSON::ParserError, 'CDX resume separator has no key' if separator_seen && resume_key.nil?
        end

        def parse_resume_key(row, separator_seen, final_row)
          key = row.first
          valid = separator_seen && final_row && key.is_a?(String) && key.bytesize.between?(1, MAX_RESUME_KEY_BYTES)
          raise JSON::ParserError, 'CDX resume key is malformed' unless valid

          key
        end

        def parse_row(row, indexes)
          raise JSON::ParserError, 'CDX row is truncated' if row.length <= indexes.values.max

          record = indexes.to_h do |field, index|
            value = row[index]
            raise JSON::ParserError, "CDX #{field} is invalid" unless value.is_a?(String)
            raise JSON::ParserError, "CDX #{field} exceeds byte limit" if value.bytesize > FIELD_LIMITS.fetch(field)

            [field, value]
          end
          raise JSON::ParserError, 'CDX timestamp is invalid' unless record['timestamp'].match?(/\A\d{14}\z/)

          record
        end
      end
    end
  end
end
