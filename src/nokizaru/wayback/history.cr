require "json"
require "time"
require "uri"
require "./limits"
require "./normalize"
require "./record"
require "./cdx"

module Nokizaru
  module Wayback
    # One selected replay snapshot. Mutated during selection (reasons/changes/
    # anchor_distance_days/previous_timestamp are filled in place), so it is a
    # class. Field order and names match the Ruby snapshot_record; statuscode/
    # mimetype/digest and previous_timestamp are omitted when unset.
    class Snapshot
      include JSON::Serializable

      property url : String
      property snapshot_url : String
      property timestamp : String
      property statuscode : String?
      property mimetype : String?
      property digest : String?
      property signal : Array(String)
      property reasons : Array(String)
      property changes : Array(String)
      property anchor_distance_days : Hash(String, Int32)
      property previous_timestamp : String?

      def initialize(
        @url : String,
        @snapshot_url : String,
        @timestamp : String,
        @signal : Array(String),
        @statuscode : String? = nil,
        @mimetype : String? = nil,
        @digest : String? = nil,
        @reasons : Array(String) = [] of String,
        @changes : Array(String) = [] of String,
        @anchor_distance_days : Hash(String, Int32) = {} of String => Int32,
        @previous_timestamp : String? = nil,
      )
      end
    end

    # Selects a small, diverse set of useful replay snapshots from CDX history:
    # one set anchored near fixed look-back windows, one set at content/status/
    # mime transitions. The record sets are bounded by the CDX caps, so
    # selection is O(n) grouping plus O(k log k) ranking of the matched
    # candidates.
    module History
      extend self

      # reason, look-back days, tolerance days.
      ANCHORS = [
        {"three_months", 90, 60},
        {"six_months", 180, 90},
        {"one_year", 365, 180},
      ]
      SIGNAL_WEIGHTS = {
        "sensitive_file"        => 5,
        "api"                   => 4,
        "interesting_parameter" => 3,
        "interesting_path"      => 3,
        "javascript"            => 2,
      }

      private record TimedRecord, record : UrlRecord, time : Time
      private record Transition, record : UrlRecord, changes : Array(String), previous_timestamp : String

      def select(records : Array(UrlRecord), historical_records : Array(UrlRecord), now : Time) : {Array(Snapshot), Array(Snapshot)}
        groups = records.group_by { |record| canonical_key(record.url) }.values
        historical = select_historical(historical_records, now)
        changed = select_changed(groups, historical, SNAPSHOT_LIMIT - historical.size)
        {historical, changed}
      end

      def replay_url(timestamp : String, url : String) : String
        "https://web.archive.org/web/#{timestamp}/#{url}"
      end

      private def select_historical(records : Array(UrlRecord), now : Time) : Array(Snapshot)
        selected = [] of Snapshot
        seen = Set(String).new
        ANCHORS.each do |(reason, days, tolerance)|
          groups = records.select { |record| record.anchor_reason == reason }
            .group_by { |record| canonical_key(record.url) }.values
          candidates = groups.compact_map { |captures| historical_candidate(captures, now, reason, days, tolerance) }
          candidates.sort_by! { |candidate| candidate_rank(candidate, reason) }
          append_historical(candidates, reason, selected, seen)
        end
        selected
      end

      private def append_historical(candidates : Array(Snapshot), reason : String, selected : Array(Snapshot), seen : Set(String)) : Nil
        candidates.each do |candidate|
          next unless seen.add?(candidate_key(candidate))

          selected << candidate
          break if selected.count { |snapshot| snapshot.reasons == [reason] } >= INTERVAL_LIMIT
        end
      end

      private def historical_candidate(captures : Array(UrlRecord), now : Time, reason : String, days : Int32, tolerance : Int32) : Snapshot?
        timed = timed_records(captures)
        return nil if timed.empty?

        url = captures.last.url
        return nil if Normalize.noise_url?(url)

        labels = Normalize.signal_labels(url)
        return nil if labels.empty? && !root_url?(url)

        anchor = now - days.days
        nearest = nearest_anchor(timed, anchor, tolerance)
        return nil if nearest.nil?

        snapshot = snapshot_record(nearest.record, labels)
        snapshot.reasons << reason
        snapshot.anchor_distance_days[reason] = ((nearest.time - anchor).abs.total_seconds / 86_400).round.to_i
        snapshot
      end

      private def nearest_anchor(timed : Array(TimedRecord), anchor : Time, tolerance : Int32) : TimedRecord?
        nearest = timed.min_by { |record| (record.time - anchor).abs }
        (nearest.time - anchor).abs <= tolerance.days ? nearest : nil
      end

      private def select_changed(groups : Array(Array(UrlRecord)), historical : Array(Snapshot), limit : Int32) : Array(Snapshot)
        return [] of Snapshot unless limit > 0

        historical_keys = historical.map { |snapshot| candidate_key(snapshot) }.to_set
        candidates = groups.compact_map { |captures| changed_candidate(captures, historical_keys) }
        candidates.sort_by! { |candidate| candidate_rank(candidate, "changed") }
        candidates.first(limit)
      end

      private def changed_candidate(captures : Array(UrlRecord), historical_keys : Set(String)) : Snapshot?
        timed = timed_records(captures)
        return nil if timed.empty?

        url = captures.last.url
        return nil if Normalize.noise_url?(url)

        labels = Normalize.signal_labels(url)
        transitions = qualifying_transitions(url, labels, transition_records(timed))
        transitions.reverse_each do |transition|
          candidate = snapshot_record(transition.record, labels)
          next if historical_keys.includes?(candidate_key(candidate))

          candidate.reasons << "changed"
          candidate.changes = transition.changes
          candidate.previous_timestamp = transition.previous_timestamp
          return candidate
        end
        nil
      end

      private def timed_records(captures : Array(UrlRecord)) : Array(TimedRecord)
        captures.compact_map { |record| timed_record(record) }.sort_by!(&.time)
      end

      private def timed_record(record : UrlRecord) : TimedRecord?
        timestamp = record.timestamp
        return nil unless timestamp.matches?(Cdx::TIMESTAMP)

        TimedRecord.new(record, Time.parse_utc(timestamp, "%Y%m%d%H%M%S"))
      rescue
        nil
      end

      private def transition_records(captures : Array(TimedRecord)) : Array(Transition)
        transitions = [] of Transition
        captures.each_cons(2, reuse: false) do |pair|
          previous, current = pair
          changes = changed_fields(previous.record, current.record)
          transitions << Transition.new(current.record, changes, previous.record.timestamp) unless changes.empty?
        end
        transitions
      end

      private def qualifying_transitions(url : String, labels : Array(String), transitions : Array(Transition)) : Array(Transition)
        return transitions if !labels.empty? || root_url?(url)

        transitions.select { |transition| !(transition.changes - ["content"]).empty? }
      end

      private def changed_fields(previous : UrlRecord, current : UrlRecord) : Array(String)
        changes = [] of String
        {"digest" => "content", "statuscode" => "status", "mimetype" => "mime_type"}.each do |field, label|
          before = field_value(previous, field)
          after = field_value(current, field)
          changes << label if !before.empty? && !after.empty? && before != after
        end
        changes
      end

      private def field_value(record : UrlRecord, field : String) : String
        case field
        when "digest"     then record.digest || ""
        when "statuscode" then record.statuscode || ""
        else                   record.mimetype || ""
        end
      end

      private def snapshot_record(record : UrlRecord, labels : Array(String)) : Snapshot
        Snapshot.new(
          url: record.url,
          snapshot_url: record.snapshot_url,
          timestamp: record.timestamp,
          statuscode: record.statuscode,
          mimetype: record.mimetype,
          digest: record.digest,
          signal: labels,
        )
      end

      private def candidate_rank(candidate : Snapshot, reason : String) : {Int32, Int32, String, String}
        score = candidate.signal.sum { |label| SIGNAL_WEIGHTS[label]? || 0 }
        if reason == "changed"
          {-score, -candidate.changes.size, candidate.url, candidate.timestamp}
        else
          distance = candidate.anchor_distance_days[reason]? || 0
          {distance, -score, candidate.url, candidate.timestamp}
        end
      end

      private def candidate_key(candidate : Snapshot) : String
        "#{canonical_key(candidate.url)}\u0000#{candidate.timestamp}"
      end

      private def canonical_key(url : String) : String
        uri = URI.parse(url)
        scheme = uri.scheme
        host = (uri.host || "").downcase
        path = uri.path.empty? ? "/" : uri.path
        port = uri.port
        default = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        port_token = default ? "" : port.to_s
        "#{host}\u0000#{port_token}\u0000#{path}\u0000#{uri.query}"
      rescue
        url
      end

      private def root_url?(url : String) : Bool
        path = URI.parse(url).path
        path.empty? || path == "/"
      rescue
        false
      end
    end
  end
end
