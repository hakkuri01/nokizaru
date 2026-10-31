require "uri"
require "set"
require "./limits"
require "./result"
require "./sample"
require "./confidence"
require "./context"
require "./signals"
require "./fields"
require "./runtime"
require "./plan"

module Nokizaru
  module DirRec
    # Assembles the scan result at finalize: re-decides every observation against
    # the final soft-404 baseline and WAF context, demotes a dominant homogeneous
    # guess cluster, buckets by confidence, ranks the high-signal paths, and
    # builds the stats block. Assembly is pure: it reads the observations the
    # runtime collected and never issues a request of its own.
    # Complexity: one O(observations) reconcile and O(k log k) ranking, once.
    module Results
      extend self

      # One reconciled candidate; decision is mutable so a homogeneous cluster can
      # be demoted in place.
      class Entry
        getter url : String
        getter status : Int32
        getter sample : Sample
        getter observed_count : Int32
        getter observed_at : Time::Instant
        getter? crawler : Bool
        property decision : Decision

        def initialize(@url, @status, @sample, @observed_count, @observed_at, @crawler, @decision)
        end
      end

      record Reconciled,
        entries : Array(Entry),
        prioritized : Array(String),
        confirmed : Array(String),
        low : Array(String)

      CANONICAL_ESCAPE = /%[0-9a-f]{2}/i

      def assemble(runtime : Runtime, info : Target, plan : UrlPlan, normalized : String, concurrency : Int32, extension_enabled : Bool) : Result
        reconciled = reconcile(runtime, plan, normalized)
        result = Result.new(info)
        result.found = runtime.all_found.uniq
        result.prioritized_found = reconciled.prioritized
        result.stdout_found = reconciled.prioritized
        result.confirmed_found = reconciled.confirmed
        result.low_confidence_found = reconciled.low
        result.high_signal_found = rank_high_signal(runtime.signal_responses, normalized, reconciled.prioritized.to_set)
        result.by_status = grouped_statuses(runtime.responses)
        result.stats = build_stats(runtime, reconciled, concurrency, extension_enabled)
        result
      end

      private def reconcile(runtime : Runtime, plan : UrlPlan, normalized : String) : Reconciled
        observations = runtime.observations
        return Reconciled.new([] of Entry, [] of String, [] of String, [] of String) if observations.empty?

        snap = runtime.context.snapshot
        crawler_set = normalized_crawler_paths(plan)
        entries = observations.map { |observation| build_entry(observation, runtime, snap, crawler_set, normalized) }
        demote_homogeneous!(entries, runtime.success)
        prioritized = entries.reject { |entry| entry.decision.level == "low" }.map(&.url)
        prioritized.uniq!
        confirmed = entries.select { |entry| entry.decision.level == "confirmed" }.map(&.url)
        confirmed.uniq!
        low = entries.select { |entry| entry.decision.level == "low" }.map(&.url)
        low.uniq!
        Reconciled.new(entries, prioritized, confirmed, low)
      end

      private def build_entry(observation : Observation, runtime : Runtime, snap : ConfidenceContext::Snapshot, crawler_set : Set(String), normalized : String) : Entry
        decision = Confidence.finding_confidence(observation.url, observation.status, observation.sample, runtime.soft_404_baseline, normalized)
        adjusted = runtime.context.adjust(decision, observation.url, snap)
        corroborated = crawler_corroborated?(observation.url, normalized, crawler_set)
        Entry.new(observation.url, observation.status, observation.sample, observation.observed_count, observation.observed_at, corroborated, adjusted)
      end

      private def demote_homogeneous!(entries : Array(Entry), successful : Int32) : Nil
        dominant = homogeneous_cluster(entries, successful)
        return if dominant.nil?

        entries.each do |entry|
          next if entry.crawler? || signature(entry) != dominant
          next unless entry.decision.level == "likely"

          entry.decision = Decision.new("low", "homogeneous_guessed_result")
        end
      end

      private def homogeneous_cluster(entries : Array(Entry), successful : Int32) : String?
        return nil if entries.size < HOMOGENEOUS_GUESS_MIN_SAMPLES
        return nil if successful <= 0 || entries.size.to_f / successful < HOMOGENEOUS_GUESS_DOMINANCE

        top = entries.map { |entry| signature(entry) }.tally.max_by? { |_signature, count| count }
        return nil if top.nil?

        dominant, count = top
        count.to_f / entries.size >= HOMOGENEOUS_GUESS_DOMINANCE ? dominant : nil
      end

      private def signature(entry : Entry) : String
        sample = entry.sample
        "#{entry.status}\u0000#{sample.content_type}\u0000#{sample.title}\u0000#{sample.fingerprint}\u0000#{sample.body_length}"
      end

      private def rank_high_signal(signal_responses : Array(Tuple(String, Int32)), normalized : String, prioritized : Set(String)) : Array(String)
        scored = signal_responses.compact_map do |(url, status)|
          score = score_path_signal(url, status, normalized)
          score > 0 && prioritized.includes?(url) ? {url, score} : nil
        end
        scored.sort_by! { |(url, score)| {-score, url.size} }
        ranked = scored.first(200).map { |(url, _score)| url }
        ranked.uniq!
        ranked
      end

      private def score_path_signal(url : String, status : Int32, normalized : String) : Int32
        path = relative_response_path(url, normalized)
        return 0 if path.empty? || path == "/"

        status_signal_score(status) + path_signal_score(path)
      rescue
        0
      end

      private def status_signal_score(code : Int32) : Int32
        return 4 if code == 401 || code == 403
        return 3 if code == 200 || code == 500
        return 1 if REDIRECT_STATUSES.includes?(code)

        0
      end

      private def path_signal_score(path : String) : Int32
        score = 0
        score += 4 if Signals.high_signal_path?(path)
        score += 1 if path.count('/') >= 2
        score -= 3 if Signals.low_information_segment?(Signals.first_path_segment(path))
        score
      end

      private def grouped_statuses(responses : Array(Tuple(String, Int32))) : Hash(String, Array(String))
        grouped = {} of String => Array(String)
        responses.each do |(url, status)|
          (grouped[status.to_s] ||= [] of String) << url
        end
        grouped
      end

      private def build_stats(runtime : Runtime, reconciled : Reconciled, concurrency : Int32, extension_enabled : Bool) : Stats
        stats = runtime.policy.stats
        total = runtime.success + runtime.errors
        elapsed = runtime.policy.elapsed_seconds

        stats.total_requests = total
        stats.successful = runtime.success
        stats.errors = runtime.errors
        stats.error_breakdown = runtime.error_kinds
        stats.elapsed_seconds = elapsed.round(2)
        stats.requests_per_second = elapsed > 0 ? (total / elapsed).round(1) : 0.0
        apply_confidence_stats(stats, reconciled.entries, runtime.start_time)
        apply_context_stats(stats, runtime.context.snapshot)
        stats
      end

      private def apply_confidence_stats(stats : Stats, entries : Array(Entry), start_time : Time::Instant) : Nil
        stats.confidence_levels = entries.map(&.decision.level).tally
        stats.confidence_reasons = entries.map(&.decision.reason).reject(&.empty?).tally
        stats.waf_sensitive_promotion_count = entries.count do |entry|
          entry.decision.level != "low" && Confidence.sensitive_status_reason?(entry.decision.reason)
        end
        first = entries.reject { |entry| entry.decision.level == "low" }.min_by?(&.observed_count)
        return if first.nil?

        stats.time_to_first_actionable_s = (first.observed_at - start_time).total_seconds.round(4)
        stats.requests_to_first_actionable = first.observed_count
      end

      private def apply_context_stats(stats : Stats, snap : ConfidenceContext::Snapshot) : Nil
        stats.waf_likelihood_score = snap.waf_likelihood_score.round(4)
        stats.waf_score_confidence = snap.waf_score_confidence
        stats.redirect_cluster_dominance_ratio = snap.redirect_cluster_dominance_ratio.round(4)
        stats.soft_404_dominance_ratio = snap.soft_404_dominance_ratio.round(4)
        stats.sensitive_status_total = snap.sensitive_status_total
        stats.sensitive_status_homogeneity_ratio = snap.sensitive_status_homogeneity_ratio.round(4)
        stats.sensitive_status_fingerprint_uniqueness_ratio = snap.sensitive_status_fingerprint_uniqueness_ratio.round(4)
        stats.context_sources_used = snap.context_sources_used
        stats.context_sources_missing = snap.context_sources_missing
      end

      private def normalized_crawler_paths(plan : UrlPlan) : Set(String)
        plan.crawler_paths.map { |path| Fields.normalize_pattern_path(canonical_path(path)) }.to_set
      end

      private def crawler_corroborated?(url : String, normalized : String, crawler_set : Set(String)) : Bool
        path = canonical_path(url)
        target_path = canonical_path(normalized).rchop("/")
        relative = path
        relative = "/" if !target_path.empty? && path == target_path
        relative = path.lchop(target_path) if !target_path.empty? && path.starts_with?("#{target_path}/")
        crawler_set.includes?(Fields.normalize_pattern_path(relative))
      end

      private def canonical_path(value : String) : String
        URI.parse(value).path.gsub(CANONICAL_ESCAPE, &.upcase)
      rescue
        value
      end

      private def relative_response_path(url : String, normalized : String) : String
        path = path_of(url)
        target_path = path_of(normalized).rchop("/")
        return path if target_path.empty? || target_path == "/"
        return "/" if path == target_path
        return path unless path.starts_with?("#{target_path}/")

        path.lchop(target_path)
      rescue
        path_of(url)
      end

      private def path_of(url : String) : String
        URI.parse(url).path.downcase
      rescue
        ""
      end
    end
  end
end
