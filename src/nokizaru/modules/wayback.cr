require "json"
require "time"
require "../wayback/limits"
require "../wayback/fetcher"
require "../wayback/query"
require "../wayback/normalize"
require "../wayback/result"
require "../http/pool"
require "../ui"

module Nokizaru
  module Modules
    # The Wayback Machine module entry. Runs the query engine and assembles the
    # typed payload (the parity contract), falling back to a failed payload on an
    # unexpected error so one archive outage never fails the whole scan.
    module Wayback
      extend self

      alias Result = Nokizaru::Wayback::Result
      alias SourceHealth = Nokizaru::Wayback::SourceHealth
      alias Snapshot = Nokizaru::Wayback::Snapshot

      # Widest Wayback presenter label ("Checking availability on Wayback
      # Machine"), so every status row aligns as the Ruby tool rendered it.
      ROW_LABEL_WIDTH = 40
      AVAIL_LABELS    = {"available" => "Available", "not_available" => "Not Available", "unknown" => "Unknown"}

      # Renders the Wayback query for the classic output and the dashboard
      # capture, in the Ruby presenter order: availability, archive-service
      # status, CDX retrieval, the selected snapshot lists, and (only when no
      # URLs were found) the manual review pivots. Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("WayBack Machine")
        availability_health = result.source_health["availability"]?
        unless availability_health.try(&.reason) == "not_requested"
          present_availability(result.availability, availability_health)
        end
        present_archive_status(result.archive_status, result.cdx_status)
        present_cdx_status(result.cdx_status, result.urls, result.source_health["cdx"]?)
        present_snapshots(result.historical_snapshots, result.changed_snapshots)
        present_manual_pivots(result.manual_pivots) if result.urls.empty?
      end

      private def present_availability(state : String, health : SourceHealth?) : Nil
        timed_out = health.try(&.status) == "timeout" || health.try(&.reason) == "timeout"
        label = timed_out ? "Timeout" : (AVAIL_LABELS[state]? || AVAIL_LABELS["unknown"])
        reason = human_status(health.try(&.reason))
        label = "#{label} (#{reason})" unless reason.empty? || reason == label
        wayback_row(state == "available" ? UI::Kind::Plus : UI::Kind::Error, "Checking availability on Wayback Machine", label)
      end

      private def present_archive_status(status : String, cdx_status : String) : Nil
        type = status == "degraded" ? UI::Kind::Error : UI::Kind::Info
        label = if cdx_status.starts_with?("partial_")
                  "Partial (#{human_status(cdx_status.lchop("partial_")).downcase})"
                elsif status == "degraded"
                  "Degraded or rate-limited"
                else
                  status.capitalize
                end
        wayback_row(type, "Archive.org service status", label)
      end

      private def present_cdx_status(cdx_status : String, urls : Array(String), health : SourceHealth?) : Nil
        if urls.empty?
          wayback_row(UI::Kind::Error, "Fetching URLs from CDX", empty_cdx_label(cdx_status, health))
          return
        end

        partial = cdx_status.starts_with?("partial")
        detail = partial ? "#{urls.size} retained" : urls.size.to_s
        detail = "#{detail} (availability fallback)" if cdx_status == "fallback"
        wayback_row(partial ? UI::Kind::Error : UI::Kind::Info, "Fetching URLs from CDX", detail)
      end

      private def empty_cdx_label(status : String, health : SourceHealth?) : String
        label = case status
                when "timeout"          then "Timeout"
                when "rate_limited"     then "Rate limited"
                when "archive_degraded" then "Archive degraded"
                else                         "Not Found"
                end
        reason = human_status(health.try(&.reason))
        reason.empty? || reason == label ? label : "#{label} (#{reason})"
      end

      private def present_snapshots(historical : Array(Snapshot), changed : Array(Snapshot)) : Nil
        wayback_row(UI::Kind::Plus, "Historical snapshots selected", historical.size.to_s)
        wayback_row(UI::Kind::Plus, "State-change snapshots selected", changed.size.to_s)
        snapshot_list("Wayback Historical Snapshots", historical) { |snapshot| human_status(snapshot.reasons.first?) }
        snapshot_list("Wayback State-Change Snapshots", changed) do |snapshot|
          changes = snapshot.changes.map { |value| human_status(value).downcase }.join(", ")
          changes.empty? ? "Changed" : "Changed (#{changes})"
        end
      end

      private def snapshot_list(title : String, snapshots : Array(Snapshot), & : Snapshot -> String) : Nil
        return if snapshots.empty?

        UI.tree_header(title)
        UI.tree_rows(snapshots.map { |snapshot| {yield(snapshot), snapshot.snapshot_url} })
      end

      private def present_manual_pivots(pivots : Hash(String, String)) : Nil
        UI.tree_header("Wayback Manual Review Links")
        UI.tree_rows([
          {"Calendar", pivots["calendar_url"]?},
          {"Changes", pivots["changes_url"]?},
          {"Availability API", pivots["availability_query_url"]?},
          {"CDX API", pivots["cdx_query_url"]?},
        ])
      end

      private def wayback_row(kind : UI::Kind, label : String, value : String) : Nil
        UI.row(kind, label, value, label_width: ROW_LABEL_WIDTH)
      end

      # Humanizes a machine reason token ("rate_limited" -> "Rate limited"), with
      # the API/CDX/HTTP acronyms upper-cased, as the Ruby presenter did.
      private def human_status(value : String?) : String
        text = value.to_s.tr("_", " ")
        return text if text.empty?

        text = text.sub(/\A./, &.upcase)
        text.gsub(/\bapi\b/i, "API").gsub(/\bcdx\b/i, "CDX").gsub(/\bhttp\b/i, "HTTP")
      end

      def collect(
        target : String,
        pool : Http::Pool = Http::Pool.new,
        cdx_url : String = Nokizaru::Wayback::CDX_URL,
        avail_url : String = Nokizaru::Wayback::AVAIL_URL,
        timeout_s : Float64 = Nokizaru::Wayback::READ_TIMEOUT,
      ) : Result
        started = Time.instant
        query = Nokizaru::Wayback::Query.new(Nokizaru::Wayback::Fetcher.new(pool), cdx_url, avail_url, timeout_s)
        begin
          build_result(query.run(target), elapsed(started))
        rescue error
          build_failure(target, query, error, elapsed(started))
        end
      end

      private def elapsed(started : Time::Instant) : Float64
        (Time.instant - started).total_seconds.round(4)
      end

      private def build_result(outcome : Nokizaru::Wayback::Outcome, elapsed : Float64) : Result
        triage = Nokizaru::Wayback::Normalize.triage(outcome.urls)
        result = Result.new
        result.status = "complete"
        result.timed_out = outcome.timed_out?
        result.archive_status = outcome.archive_status
        result.cdx_status = outcome.cdx_status
        result.cdx_reasons = outcome.cdx_reasons
        result.source_health = outcome.source_health
        result.urls = outcome.urls
        result.url_records = outcome.url_records
        result.historical_snapshots = outcome.historical_snapshots
        result.changed_snapshots = outcome.changed_snapshots
        result.high_signal_urls = triage.review_urls
        result.manual_pivots = outcome.manual_pivots
        result.elapsed_s = elapsed
        result.availability = outcome.availability_state
        result.availability_reason = outcome.availability_reason
        apply_triage(result, triage)
        result
      end

      private def apply_triage(result : Result, triage : Nokizaru::Wayback::Triage) : Nil
        result.javascript_urls = triage.javascript_urls
        result.api_urls = triage.api_urls
        result.interesting_path_urls = triage.interesting_path_urls
        result.interesting_parameter_urls = triage.interesting_parameter_urls
        result.sensitive_file_urls = triage.sensitive_file_urls
        result.review_urls = triage.review_urls
        result.parameter_counts = triage.parameter_counts
      end

      private def build_failure(target : String, query : Nokizaru::Wayback::Query, error : Exception, elapsed : Float64) : Result
        reason = "exception"
        result = Result.new
        result.status = "failed"
        result.error = "#{error.class}: #{error.message}"
        result.archive_status = "degraded"
        result.cdx_status = "archive_degraded"
        result.cdx_reasons = [reason]
        result.source_health = {
          "cdx"          => Nokizaru::Wayback::SourceHealth.new("failed", reason: reason),
          "availability" => Nokizaru::Wayback::SourceHealth.new("skipped", reason: reason),
        }
        result.availability = "unknown"
        result.availability_reason = reason
        result.manual_pivots = query.manual_pivots(target)
        result.elapsed_s = elapsed
        result
      end
    end
  end
end
