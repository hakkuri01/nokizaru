require "json"
require "./limits"
require "./record"
require "./history"
require "./query"

module Nokizaru
  module Wayback
    # The Wayback payload, serialized as the parity contract. Field order and
    # names match the Ruby wayback_payload (schema_version first, then status/
    # error, the archive and CDX health, the URL and snapshot sets, the manual
    # pivots, elapsed, availability, and the flattened triage categories).
    # high_signal_urls duplicates review_urls, as in the Ruby tool. error and
    # availability_reason stay present as null when unset; every other field is
    # always present (a failed query still emits empty arrays and an empty
    # parameter_counts, matching the Ruby failure payload).
    class Result
      include JSON::Serializable

      property schema_version : Int32 = SCHEMA_VERSION
      property status : String = "complete"

      @[JSON::Field(emit_null: true)]
      property error : String? = nil

      property? timed_out : Bool = false
      property archive_status : String = "unknown"
      property cdx_status : String = ""
      property cdx_reasons : Array(String) = [] of String
      property source_health : Hash(String, SourceHealth) = {} of String => SourceHealth
      property urls : Array(String) = [] of String
      property url_records : Array(UrlRecord) = [] of UrlRecord
      property historical_snapshots : Array(Snapshot) = [] of Snapshot
      property changed_snapshots : Array(Snapshot) = [] of Snapshot
      property high_signal_urls : Array(String) = [] of String
      property manual_pivots : Hash(String, String) = {} of String => String
      property elapsed_s : Float64 = 0.0
      property availability : String = "unknown"

      @[JSON::Field(emit_null: true)]
      property availability_reason : String? = nil

      property javascript_urls : Array(String) = [] of String
      property api_urls : Array(String) = [] of String
      property interesting_path_urls : Array(String) = [] of String
      property interesting_parameter_urls : Array(String) = [] of String
      property sensitive_file_urls : Array(String) = [] of String
      property review_urls : Array(String) = [] of String
      property parameter_counts : Hash(String, Int32) = {} of String => Int32

      def initialize
      end
    end
  end
end
