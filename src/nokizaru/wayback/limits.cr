module Nokizaru
  module Wayback
    # The archive.org endpoints and the bounds shared across the Wayback module.
    AVAIL_URL = "https://archive.org/wayback/available"
    CDX_URL   = "https://web.archive.org/cdx/search/cdx"

    # Default total budget when the caller passes none, and the ceilings on how
    # many snapshots are selected overall and per anchor interval.
    TOTAL_TIMEOUT  = 60.0
    SNAPSHOT_LIMIT =   50
    INTERVAL_LIMIT =    5

    # The payload schema version, carried verbatim for parity with the Ruby tool.
    SCHEMA_VERSION = 4
  end
end
