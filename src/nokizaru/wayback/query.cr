require "json"
require "uri"
require "time"
require "./limits"
require "./normalize"
require "./record"
require "./cdx"
require "./history"
require "./fetcher"

module Nokizaru
  module Wayback
    # One source's health line (availability or cdx). records is always present;
    # reason is omitted when nil. Matches the Ruby source_health hash.
    struct SourceHealth
      include JSON::Serializable

      getter status : String
      getter records : Int32
      getter reason : String?

      def initialize(@status : String, @records : Int32 = 0, @reason : String? = nil)
      end
    end

    # The closest archived snapshot from the availability API.
    record Closest, url : String, timestamp : String, status : String

    # The availability-API outcome: a state, the closest snapshot when available,
    # and a reason when it could not be determined.
    struct AvailabilityCheck
      getter state : String
      getter closest : Closest?
      getter reason : String?

      def initialize(@state : String, @closest : Closest? = nil, @reason : String? = nil)
      end
    end

    # One history fetch's records plus its status and reasons.
    struct HistoryResult
      getter records : Array(UrlRecord)
      getter status : String
      getter reasons : Array(String)

      def initialize(@records : Array(UrlRecord), @status : String, @reasons : Array(String))
      end
    end

    # The assembled query outcome the module turns into the payload.
    struct Outcome
      getter urls : Array(String)
      getter cdx_status : String
      getter cdx_reasons : Array(String)
      getter url_records : Array(UrlRecord)
      getter availability_state : String
      getter availability_reason : String?
      getter source_health : Hash(String, SourceHealth)
      getter historical_snapshots : Array(Snapshot)
      getter changed_snapshots : Array(Snapshot)
      getter archive_status : String
      getter manual_pivots : Hash(String, String)
      getter? timed_out : Bool

      def initialize(
        @urls : Array(String),
        @cdx_status : String,
        @cdx_reasons : Array(String),
        @url_records : Array(UrlRecord),
        @availability_state : String,
        @availability_reason : String?,
        @source_health : Hash(String, SourceHealth),
        @historical_snapshots : Array(Snapshot),
        @changed_snapshots : Array(Snapshot),
        @archive_status : String,
        @manual_pivots : Hash(String, String),
        @timed_out : Bool,
      )
      end
    end

    # Orchestrates the Wayback query: fetch the anchor windows and the full CDX
    # history, combine them, fall back to the availability API when CDX returned
    # nothing usable, then classify health, archive status, and select snapshots.
    # Complexity: 3 independent anchors and initial history run on owned pools;
    # subsequent cursor pages are sequential, at most MAX_CDX_RECORDS/PAGE_SIZE
    # paged requests (capped by records and bytes) + at most one availability
    # request; selection and health are O(n) over the capped record set.
    class Query
      MAX_CDX_RECORDS      = 50_000
      MAX_CDX_RECORD_BYTES = 32 * 1024 * 1024
      PAGE_DELAY           = 0.25
      UNHEALTHY_STATUSES   = {"failed", "timeout", "rate_limited"}
      DEGRADED_REASONS     = {
        "timeout", "request_failed", "exception", "service_unavailable", "rate_limited",
        "invalid_response", "response_too_large", "record_limit", "byte_limit",
      }

      def initialize(@fetcher : Fetcher, @cdx_url : String, @avail_url : String, @timeout_s : Float64)
      end

      def run(target : String) : Outcome
        now = Time.utc
        budget = @timeout_s > 0 ? @timeout_s : TOTAL_TIMEOUT
        started = @fetcher.now
        deadline = started + budget.seconds
        network_deadline = deadline - POST_PROCESSING_BUDGET.seconds
        anchor_deadline = {started + (budget * ANCHOR_BUDGET_SHARE).seconds, network_deadline}.min
        history_deadline = deadline - {POST_PROCESSING_BUDGET, {budget * 0.10, 5.0}.min}.max.seconds
        anchor, initial = fetch_initial(target, now, anchor_deadline, history_deadline)
        change = fetch_cdx_history(target, initial, history_deadline)
        combined = combine([anchor, change])
        availability, wayback_records, fallback = fallback_records(target, combined, network_deadline)

        urls, records = finalize_records(wayback_records)
        unique_cdx_urls = combined.records.map(&.url).to_set.size
        health = {
          "availability" => availability_health(availability, fallback ? records.size : 0),
          "cdx"          => cdx_health(combined, unique_cdx_urls),
        }
        status = fallback ? "fallback" : combined.status
        historical, changed = select_snapshots(change.records, anchor.records, status, now)
        archive = archive_status(availability.state, status, combined.reasons, health)
        Outcome.new(
          urls, status, combined.reasons, records, availability.state, availability.reason,
          health, historical, changed, archive, manual_pivots(target),
          status.includes?("timeout") || combined.reasons.includes?("timeout"),
        )
      end

      private def fetch_initial(target : String, now : Time, anchor_deadline : Time::Instant, history_deadline : Time::Instant) : {HistoryResult, Cdx::Page}
        urls = History::ANCHORS.map do |(_, days, tolerance)|
          anchor = now - days.days
          payload = Cdx.build_payload(target, collapse: "urlkey",
            from: timestamp_value(anchor - tolerance.days), to: timestamp_value(anchor + tolerance.days))
          Cdx.query_url(@cdx_url, payload)
        end
        urls << Cdx.query_url(@cdx_url, Cdx.build_payload(target))
        pages = Array(Cdx::Page).new(4) { Cdx::Page.new(reason: "timeout") }
        done = Channel(Nil).new(4)
        urls.each_with_index do |url, index|
          spawn do
            pages[index] = fetch_owned_page(url, index == 3 ? history_deadline : anchor_deadline)
            done.send(nil)
          end
        end
        4.times { done.receive }
        anchors = History::ANCHORS.map_with_index do |(reason, _, _), index|
          anchor_result(pages[index], target, reason)
        end
        {combine(anchors), pages[3]}
      end

      private def fetch_owned_page(url : String, deadline : Time::Instant) : Cdx::Page
        worker = @fetcher.worker
        Cdx.fetch_page(worker, url, deadline)
      rescue
        Cdx::Page.new(reason: "exception")
      ensure
        worker.try(&.close)
      end

      private def anchor_result(page : Cdx::Page, target : String, reason : String) : HistoryResult
        reason_text = page.reason
        return history_result([] of UrlRecord, response_failure_status(reason_text), [reason_text]) unless reason_text.nil?

        records = page.rows.compact_map { |row| history_record(row, target, reason) }
        resume = page.resume_key
        history_result(records, resume ? "partial_limit" : "complete", resume ? ["record_limit"] : [] of String)
      end

      private def fetch_cdx_history(target : String, page : Cdx::Page, deadline : Time::Instant) : HistoryResult
        payload = Cdx.build_payload(target)
        records = [] of UrlRecord
        record_bytes = 0
        resume_key = nil
        seen = Set(String).new
        loop do
          terminal = append_or_stop(page, records, pointerof(record_bytes), target, seen)
          return terminal unless terminal.nil?

          resume_key = page.resume_key
          @fetcher.wait(PAGE_DELAY.seconds, deadline)
          return history_result(records, partial_status("timeout", records), ["timeout"]) if @fetcher.now >= deadline

          resume_key.try { |key| payload["resumeKey"] = key }
          page = Cdx.fetch_page(@fetcher, Cdx.query_url(@cdx_url, payload), deadline)
        end
      end

      # Returns a terminal HistoryResult when the page ends the loop, or nil to
      # continue to the next page.
      private def append_or_stop(page : Cdx::Page, records : Array(UrlRecord), record_bytes : Int32*, target : String, seen : Set(String)) : HistoryResult?
        reason = page.reason
        return history_result(records, partial_status(reason, records), [reason]) unless reason.nil?

        limit_reason = append_page(records, record_bytes, page.rows, target)
        return history_result(records, "partial_limit", [limit_reason]) unless limit_reason.nil?

        next_key = page.resume_key
        return history_result(records, "complete", [] of String) if next_key.nil? || next_key.empty?
        return history_result(records, "partial_failure", ["repeated_resume_key"]) unless seen.add?(next_key)

        nil
      end

      private def append_page(records : Array(UrlRecord), record_bytes : Int32*, rows : Array(Cdx::Row), target : String) : String?
        rows.each do |row|
          record = history_record(row, target)
          next if record.nil?

          size = record.byte_size
          return "record_limit" if records.size >= MAX_CDX_RECORDS
          return "byte_limit" if record_bytes.value + size > MAX_CDX_RECORD_BYTES

          records << record
          record_bytes.value += size
        end
        nil
      end

      private def history_record(row : Cdx::Row, target : String, anchor_reason : String? = nil) : UrlRecord?
        url = row.original
        return nil if Normalize.filter_urls([url], target: target, include_noise: true, exact_host: true).empty?

        UrlRecord.new(
          url: url, source: "wayback", timestamp: row.timestamp,
          snapshot_url: History.replay_url(row.timestamp, url),
          mimetype: row.mimetype, statuscode: row.statuscode, digest: row.digest,
          anchor_reason: anchor_reason,
        )
      end

      private def combine(results : Array(HistoryResult)) : HistoryResult
        records = results.flat_map(&.records)
        reasons = results.flat_map(&.reasons)
        reasons.uniq!
        status = combined_status(results.map(&.status), records)
        history_result(records, status, reasons)
      end

      private def combined_status(statuses : Array(String), records : Array(UrlRecord)) : String
        text = statuses.join(' ')
        return records.empty? ? "timeout" : "partial_timeout" if text.includes?("timeout")
        return records.empty? ? "rate_limited" : "partial_rate_limited" if text.includes?("rate_limited")
        return "partial_limit" if statuses.includes?("partial_limit")
        return "partial_failure" if text.includes?("failure") || statuses.includes?("archive_degraded")
        return "not_found" if records.empty?

        "complete"
      end

      private def history_result(records : Array(UrlRecord), status : String, reasons : Array(String)) : HistoryResult
        effective = records.empty? && status == "complete" ? "not_found" : status
        HistoryResult.new(records, effective, reasons)
      end

      private def partial_status(reason : String?, records : Array(UrlRecord)) : String
        return response_failure_status(reason) if records.empty?
        return "partial_timeout" if reason == "timeout"
        return "partial_rate_limited" if reason == "rate_limited"

        "partial_failure"
      end

      private def response_failure_status(reason : String?) : String
        return "timeout" if reason == "timeout"
        return "rate_limited" if reason == "rate_limited"

        "archive_degraded"
      end

      private def select_snapshots(change_records : Array(UrlRecord), anchor_records : Array(UrlRecord), status : String, now : Time) : {Array(Snapshot), Array(Snapshot)}
        return {[] of Snapshot, [] of Snapshot} if status == "fallback"

        History.select(change_records, anchor_records, now)
      end

      private def fallback_records(target : String, combined : HistoryResult, deadline : Time::Instant) : {AvailabilityCheck, Array(UrlRecord), Bool}
        return {AvailabilityCheck.new("unknown", nil, "not_requested"), combined.records, false} if cdx_finished?(combined)

        availability = check_availability(target, {deadline, @fetcher.now + AVAIL_TIMEOUT.seconds}.min)
        records = availability_records(availability, target)
        {availability, records, !records.empty?}
      end

      private def cdx_finished?(history : HistoryResult) : Bool
        !history.records.empty? || history.status == "complete" || history.status == "not_found"
      end

      private def check_availability(target : String, deadline : Time::Instant) : AvailabilityCheck
        url = "#{@avail_url}?#{URI::Params.encode({"url" => target})}"
        result = @fetcher.get(url, deadline)
        return AvailabilityCheck.new("unknown", nil, result.error_kind.timeout? ? "timeout" : "request_failed") if result.error?

        status = result.status
        return AvailabilityCheck.new("unknown", nil, Cdx.response_reason(status)) unless status == 200
        return AvailabilityCheck.new("unknown", nil, "response_too_large") if (result.body || "").bytesize > 1024 * 1024

        availability_state(result.body || "")
      rescue
        AvailabilityCheck.new("unknown", nil, "exception")
      end

      private def availability_state(body : String) : AvailabilityCheck
        snaps = JSON.parse(body)["archived_snapshots"]?.try(&.as_h?)
        return AvailabilityCheck.new("not_available", nil, nil) if snaps.nil? || snaps.empty?

        AvailabilityCheck.new("available", extract_closest(snaps["closest"]?), nil)
      rescue JSON::ParseException
        AvailabilityCheck.new("unknown", nil, "exception")
      end

      private def extract_closest(value : JSON::Any?) : Closest?
        hash = value.try(&.as_h?)
        return nil if hash.nil?

        url = hash["url"]?.try(&.as_s?) || ""
        return nil if url.empty?

        Closest.new(url, hash["timestamp"]?.try(&.as_s?) || "", hash["status"]?.try(&.as_s?) || "")
      end

      private def availability_records(availability : AvailabilityCheck, target : String) : Array(UrlRecord)
        closest = availability.closest
        return [] of UrlRecord if closest.nil?

        url = Normalize.original_url_from_archive_snapshot(closest.url)
        return [] of UrlRecord if url.empty?
        return [] of UrlRecord if Normalize.filter_urls([url], target: target, include_noise: true, exact_host: true).empty?

        [UrlRecord.new(url: url, source: "availability", timestamp: closest.timestamp, snapshot_url: closest.url, statuscode: closest.status)]
      end

      private def finalize_records(records : Array(UrlRecord)) : {Array(String), Array(UrlRecord)}
        seen = Set(String).new
        unique = [] of UrlRecord
        records.each { |record| unique << record if seen.add?(record.url) }
        {unique.map(&.url), unique}
      end

      private def availability_health(availability : AvailabilityCheck, record_count : Int32) : SourceHealth
        return SourceHealth.new("skipped", reason: "not_requested") if availability.reason == "not_requested"

        case availability.state
        when "available"
          record_count > 0 ? SourceHealth.new("found", records: record_count) : SourceHealth.new("failed", reason: "invalid_snapshot")
        when "not_available"
          SourceHealth.new("empty")
        else
          SourceHealth.new(availability.reason == "timeout" ? "timeout" : "failed", reason: availability.reason)
        end
      end

      private def cdx_health(history : HistoryResult, records : Int32) : SourceHealth
        status = history.status
        health_status = if status == "complete"
                          records > 0 ? "found" : "empty"
                        elsif status == "not_found"
                          "empty"
                        elsif status.includes?("timeout")
                          "timeout"
                        elsif status.includes?("rate_limited")
                          "rate_limited"
                        else
                          "failed"
                        end
        SourceHealth.new(health_status, records, health_reason(status, history.reasons))
      end

      private def health_reason(status : String, reasons : Array(String)) : String?
        return "timeout" if status.includes?("timeout")
        return "rate_limited" if status.includes?("rate_limited")

        reasons.last?
      end

      private def archive_status(availability_state : String, cdx_status : String, cdx_reasons : Array(String), health : Hash(String, SourceHealth)) : String
        return "degraded" if unhealthy_sources?(health)
        return "degraded" if cdx_status.starts_with?("partial") || cdx_status == "archive_degraded"
        return "degraded" if cdx_reasons.any? { |reason| DEGRADED_REASONS.includes?(reason) }
        return "healthy" if {"complete", "not_found", "fallback"}.includes?(cdx_status)
        return "healthy" if availability_state == "available"

        "unknown"
      end

      private def unhealthy_sources?(health : Hash(String, SourceHealth)) : Bool
        {"availability", "cdx"}.any? { |source| UNHEALTHY_STATUSES.includes?(health[source]?.try(&.status)) }
      end

      # The manual review links; public so the module's failure path can build
      # them without a full query run.
      def manual_pivots(target : String) : Hash(String, String)
        encoded = URI::Params.encode({"url" => target})
        payload = Cdx.build_payload(target).merge({"limit" => "50"})
        {
          "calendar_url"           => "https://web.archive.org/web/*/#{URI.encode_path(target)}",
          "availability_query_url" => "#{@avail_url}?#{encoded}",
          "cdx_query_url"          => "#{@cdx_url}?#{URI::Params.encode(payload)}",
          "changes_url"            => "https://web.archive.org/web/changes/#{URI.encode_path(target)}",
        }
      rescue ArgumentError
        {} of String => String
      end

      private def timestamp_value(time : Time) : String
        time.to_utc.to_s("%Y%m%d%H%M%S")
      end
    end
  end
end
