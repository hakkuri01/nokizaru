require "json"

module Nokizaru
  module Wayback
    # One archived URL with its provenance. Built from a CDX row or the
    # availability closest-snapshot; mimetype/digest are absent for availability
    # records and anchor_reason is present only for anchor-window records, so each
    # is nilable and omitted when unset (matching the Ruby record hashes). Field
    # order follows the Ruby history_record merge order.
    struct UrlRecord
      include JSON::Serializable

      getter url : String
      getter source : String
      getter timestamp : String
      getter mimetype : String?
      getter statuscode : String?
      getter digest : String?
      getter snapshot_url : String
      getter anchor_reason : String?

      def initialize(
        @url : String,
        @source : String,
        @timestamp : String,
        @snapshot_url : String,
        @mimetype : String? = nil,
        @statuscode : String? = nil,
        @digest : String? = nil,
        @anchor_reason : String? = nil,
      )
      end

      # The byte weight of a record, for the CDX byte-budget cap (sums every
      # stored value as the Ruby record_size did).
      def byte_size : Int32
        size = url.bytesize + source.bytesize + timestamp.bytesize + snapshot_url.bytesize
        size += mimetype.try(&.bytesize) || 0
        size += statuscode.try(&.bytesize) || 0
        size += digest.try(&.bytesize) || 0
        size += anchor_reason.try(&.bytesize) || 0
        size
      end
    end
  end
end
