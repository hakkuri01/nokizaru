require "json"
require "uri"
require "./normalize"
require "./fetcher"

module Nokizaru
  module Wayback
    # The strict CDX request/response boundary. The response is untrusted JSON
    # from web.archive.org, so parsing is defensive: byte-capped, one O(bytes)
    # pass, every field type/size checked and rejected on anything unexpected.
    # A page is at most PAGE_SIZE rows.
    module Cdx
      extend self

      FIELDS       = %w[timestamp original mimetype statuscode digest]
      FIELD_LIMITS = {
        "timestamp" => 14, "original" => Normalize::MAX_URL_LENGTH,
        "mimetype" => 256, "statuscode" => 16, "digest" => 256,
      }
      PAGE_SIZE            = 1000
      MAX_BODY_BYTES       = 8 * 1024 * 1024
      MAX_RESUME_KEY_BYTES = 4096

      # A valid CDX timestamp: exactly 14 digits.
      TIMESTAMP = /\A\d{14}\z/

      # A malformed CDX response; caught by the fetch boundary and reported as
      # `invalid_response`.
      class ParseError < Exception
      end

      # One parsed CDX data row (the five requested fields, all present).
      struct Row
        getter timestamp : String
        getter original : String
        getter mimetype : String
        getter statuscode : String
        getter digest : String

        def initialize(@timestamp, @original, @mimetype, @statuscode, @digest)
        end
      end

      # One fetched page: the parsed rows, the resume key for the next page (nil
      # when finished), and a failure reason (nil on success).
      struct Page
        getter rows : Array(Row)
        getter resume_key : String?
        getter reason : String?

        def initialize(@rows : Array(Row) = [] of Row, @resume_key : String? = nil, @reason : String? = nil)
        end
      end

      def build_payload(target : String, collapse : String? = nil, from : String? = nil, to : String? = nil) : Hash(String, String)
        host = (URI.parse(target).host || "").downcase.rchop(".")
        raise ArgumentError.new("Wayback target must include a hostname") if host.empty?

        payload = {
          "url"           => "#{host}/",
          "matchType"     => "host",
          "output"        => "json",
          "fl"            => FIELDS.join(","),
          "filter"        => exact_original_filter(host),
          "limit"         => PAGE_SIZE.to_s,
          "showResumeKey" => "true",
        }
        payload["collapse"] = collapse if collapse
        payload["from"] = from if from
        payload["to"] = to if to
        payload
      end

      def exact_original_filter(host : String) : String
        "original:(?i)^https?://#{Regex.escape(host)}(?::[0-9]+)?(?:/|$)"
      end

      def query_url(base : String, payload : Hash(String, String)) : String
        "#{base}?#{URI::Params.encode(payload)}"
      end

      # Maps an HTTP status to a CDX failure reason.
      def response_reason(status : Int32?) : String
        return "rate_limited" if status == 429
        return "service_unavailable" if status && status >= 500 && status <= 599

        "http_#{status}"
      end

      # Fetches and parses one page, translating every failure mode into a reason
      # string rather than raising.
      def fetch_page(fetcher : Fetcher, url : String, deadline : Time::Instant) : Page
        result = fetcher.get(url, deadline)
        return Page.new(reason: result.error_kind.timeout? ? "timeout" : "request_failed") if result.error?

        status = result.status
        return Page.new(reason: response_reason(status)) unless status == 200
        return Page.new(reason: "response_too_large") if oversized?(result)

        rows, resume_key = parse(result.body || "")
        Page.new(rows, resume_key, nil)
      rescue ParseError
        Page.new(reason: "invalid_response")
      rescue
        Page.new(reason: "exception")
      end

      def parse(body : String) : {Array(Row), String?}
        raise ParseError.new("CDX response exceeds byte limit") if body.bytesize > MAX_BODY_BYTES

        array = JSON.parse(body).as_a?
        raise ParseError.new("CDX response is not an array") if array.nil?

        indexes = indexes_for(array.first?)
        parse_rows(array[1..]? || [] of JSON::Any, indexes)
      rescue JSON::ParseException
        raise ParseError.new("CDX response is not valid JSON")
      end

      private def oversized?(result : Http::Result) : Bool
        declared = result.headers["Content-Length"]?.try(&.to_i?)
        body_size = (result.body || "").bytesize
        (declared && declared > MAX_BODY_BYTES) || body_size > MAX_BODY_BYTES
      end

      private def indexes_for(header : JSON::Any?) : Hash(String, Int32)
        row = header.try(&.as_a?)
        raise ParseError.new("CDX response header is invalid") if row.nil?

        indexes = {} of String => Int32
        FIELDS.each do |field|
          matches = row.count { |value| value.as_s? == field }
          raise ParseError.new("CDX response fields are incomplete or duplicated") unless matches == 1

          index = row.index { |value| value.as_s? == field }
          raise ParseError.new("CDX field missing") if index.nil?

          indexes[field] = index
        end
        indexes
      end

      private def parse_rows(rows : Array(JSON::Any), indexes : Hash(String, Int32)) : {Array(Row), String?}
        parsed = [] of Row
        resume_key = nil
        separator_seen = false
        rows.each_with_index do |value, index|
          row = value.as_a?
          raise ParseError.new("CDX row is not an array") if row.nil?

          if row.empty?
            separator_seen = true
            next
          end
          if row.size == 1
            resume_key = parse_resume_key(row, separator_seen, index == rows.size - 1)
            next
          end
          raise ParseError.new("CDX data follows resume separator") if separator_seen
          raise ParseError.new("CDX response exceeds page limit") if parsed.size >= PAGE_SIZE

          parsed << parse_row(row, indexes)
        end
        raise ParseError.new("CDX resume separator has no key") if separator_seen && resume_key.nil?

        {parsed, resume_key}
      end

      private def parse_resume_key(row : Array(JSON::Any), separator_seen : Bool, final_row : Bool) : String
        key = row.first.as_s?
        valid = separator_seen && final_row && !key.nil? && (1..MAX_RESUME_KEY_BYTES).includes?(key.bytesize)
        raise ParseError.new("CDX resume key is malformed") if key.nil? || !valid

        key
      end

      private def parse_row(row : Array(JSON::Any), indexes : Hash(String, Int32)) : Row
        raise ParseError.new("CDX row is truncated") if row.size <= indexes.values.max

        values = {} of String => String
        indexes.each do |field, index|
          value = row[index].as_s?
          raise ParseError.new("CDX #{field} is invalid") if value.nil?
          raise ParseError.new("CDX #{field} exceeds byte limit") if value.bytesize > FIELD_LIMITS[field]

          values[field] = value
        end
        timestamp = values["timestamp"]
        raise ParseError.new("CDX timestamp is invalid") unless timestamp.matches?(TIMESTAMP)

        Row.new(timestamp, values["original"], values["mimetype"], values["statuscode"], values["digest"])
      end
    end
  end
end
