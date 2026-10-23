require "json"
require "../paths"
require "../run_state"

module Nokizaru
  module Exporters
    # The plain-text exporter. meta and findings are read from the typed tree; the
    # free-form per-module payloads are serialized once from the typed `modules`
    # object and walked for display. The Wayback payload is rendered into readable
    # sections (categories, snapshots, sources, provenance) as the Ruby tool did,
    # rather than dumped. The file is written owner-only.
    module Txt
      extend self

      # The URL category keys the Wayback payload groups under, in display order.
      WAYBACK_CATEGORIES = %w[
        review_urls javascript_urls api_urls
        interesting_path_urls interesting_parameter_urls sensitive_file_urls
      ]

      def write(run : RunState, path : String) : Nil
        File.open(path, "w", perm: Paths::PRIVATE_FILE) do |file|
          write_meta(file, run.meta)
          write_findings(file, run.findings)
          write_modules(file, module_payloads(run))
        end
      end

      # Serializes the typed `modules` object to a name-keyed map for display
      # iteration. Unset nilable module fields are omitted by the serializer, so
      # only modules that actually ran appear, matching the Ruby run hash. The
      # encode is one O(n) pass over the bounded, once-per-scan export payload,
      # off every hot path (the json contract exporter avoids the round-trip).
      def module_payloads(run : RunState) : Hash(String, JSON::Any)
        JSON.parse(run.modules.to_json).as_h
      end

      def write_meta(file : IO, meta : Meta) : Nil
        file.puts("Target: #{meta.target}")
        file.puts("Started: #{meta.started_at}")
        ended = meta.ended_at
        file.puts("Ended: #{ended}") if ended
        file.puts
      end

      def write_findings(file : IO, findings : Array(Finding)) : Nil
        return if findings.empty?

        file.puts("Findings")
        file.puts("========")
        findings.each { |finding| write_finding(file, finding) }
        file.puts
      end

      def write_finding(file : IO, finding : Finding) : Nil
        file.puts("[#{finding.severity.upcase}] #{finding.title}")
        evidence = finding.evidence
        file.puts("  Evidence: #{evidence}") if evidence
        recommendation = finding.recommendation
        file.puts("  Recommendation: #{recommendation}") if recommendation
        file.puts
      end

      def write_modules(file : IO, modules : Hash(String, JSON::Any)) : Nil
        modules.each do |name, payload|
          file.puts(name)
          file.puts("=" * name.size)
          if name == "wayback" && payload.as_h?
            write_wayback(file, payload)
          else
            string = payload.as_s?
            file.puts(string || payload.to_pretty_json)
          end
          file.puts
        end
      end

      def write_wayback(file : IO, payload : JSON::Any) : Nil
        file.puts("Archive Status: #{opt_s(payload, "archive_status") || opt_s(payload, "status")}")
        status = opt_s(payload, "status")
        file.puts("Module Status: #{status}") if status
        error = opt_s(payload, "error")
        file.puts("Error: #{error}") if error
        write_wayback_sources(file, payload["source_health"]?)
        write_wayback_categories(file, payload)
        write_wayback_snapshots(file, "Historical snapshots", array_of(payload, "historical_snapshots"))
        write_wayback_snapshots(file, "State-change snapshots", array_of(payload, "changed_snapshots"))
        write_wayback_records(file, array_of(payload, "url_records"))
        write_wayback_urls(file, array_of(payload, "urls"))
        write_wayback_pivots(file, payload["manual_pivots"]?)
      end

      private def write_wayback_sources(file : IO, sources : JSON::Any?) : Nil
        table = sources.try(&.as_h?)
        return if table.nil? || table.empty?

        file.puts("Sources")
        table.keys.sort!.each do |name|
          health = table[name]
          details = [opt_s(health, "status"), opt_s(health, "reason"), "records=#{opt_s(health, "records")}"]
          file.puts("  #{name}: #{details.compact.reject(&.empty?).join(" ")}")
        end
      end

      private def write_wayback_categories(file : IO, payload : JSON::Any) : Nil
        WAYBACK_CATEGORIES.each do |key|
          urls = strings(payload, key)
          next if urls.empty?

          file.puts("#{category_label(key)} (#{urls.size})")
          urls.each { |url| file.puts("  #{url}") }
        end
        write_parameter_counts(file, payload["parameter_counts"]?)
      end

      private def category_label(key : String) : String
        key.rchop("_urls").gsub('_', ' ').capitalize
      end

      private def write_parameter_counts(file : IO, counts : JSON::Any?) : Nil
        table = counts.try(&.as_h?)
        return if table.nil? || table.empty?

        pairs = table.map { |name, count| "#{name}=#{count.as_s? || count.raw.to_s}" }
        file.puts("Parameters: #{pairs.join(", ")}")
      end

      private def write_wayback_snapshots(file : IO, label : String, snapshots : Array(JSON::Any)) : Nil
        return if snapshots.empty?

        file.puts("#{label} (#{snapshots.size})")
        snapshots.each do |snapshot|
          reasons = strings(snapshot, "reasons").join(",")
          changes = strings(snapshot, "changes")
          reasons += "(#{changes.join(",")})" unless changes.empty?
          file.puts("  #{opt_s(snapshot, "timestamp")}\t#{reasons}\t#{opt_s(snapshot, "snapshot_url")}")
        end
      end

      private def write_wayback_records(file : IO, records : Array(JSON::Any)) : Nil
        return if records.empty?

        file.puts("Provenance (#{records.size})")
        records.each do |record|
          sources = strings(record, "sources").join(",")
          sources = (opt_s(record, "source") || "") if sources.empty?
          file.puts("  #{sources}\t#{opt_s(record, "url")}")
        end
      end

      private def write_wayback_urls(file : IO, urls : Array(JSON::Any)) : Nil
        return if urls.empty?

        file.puts("Raw URLs (#{urls.size})")
        urls.each { |url| file.puts("  #{url.as_s? || url.raw.to_s}") }
      end

      private def write_wayback_pivots(file : IO, pivots : JSON::Any?) : Nil
        table = pivots.try(&.as_h?)
        return if table.nil? || table.empty?

        file.puts("Manual Pivots")
        table.keys.sort!.each do |name|
          value = table[name]
          file.puts("  #{name}: #{value.as_s? || value.raw.to_s}")
        end
      end

      private def opt_s(payload : JSON::Any, key : String) : String?
        value = payload[key]?
        return nil if value.nil? || value.raw.nil?

        value.as_s? || value.raw.to_s
      end

      private def array_of(payload : JSON::Any, key : String) : Array(JSON::Any)
        payload[key]?.try(&.as_a?) || [] of JSON::Any
      end

      private def strings(payload : JSON::Any, key : String) : Array(String)
        array_of(payload, key).compact_map(&.as_s?)
      end
    end
  end
end
