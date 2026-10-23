require "uri"
require "./limits"
require "./sample"
require "./fields"
require "./signals"
require "./confidence"
require "../modules/headers"
require "../modules/crawler"

module Nokizaru
  module DirRec
    # Scan-wide context for noise suppression: running counters of soft-404
    # matches, redirect-pattern clustering, and sensitive-status homogeneity,
    # plus edge/WAF hints read once from the headers and crawler results. From
    # these it derives a WAF-likelihood score and downgrades confidence decisions
    # that look like anti-enumeration noise. Ports the deferred context/WAF part
    # of dirrec/confidence.rb. update! is O(1) per response; the snapshot is
    # memoized and recomputed only after a change.
    class ConfidenceContext
      SENSITIVE       = {401, 403, 405, 500}
      HINT_NAMES      = %w[headers_edge_hint crawler_blocked_hint crawler_low_unique_hint]
      EDGE_VENDORS    = %w[cloudflare akamai sucuri imperva]
      CRAWLER_BLOCKED = /HTTP status (403|405|429)\b/

      # The derived context ratios and WAF score, shared with the stats block.
      struct Snapshot
        getter waf_likelihood_score : Float64
        getter waf_score_confidence : String
        getter redirect_cluster_dominance_ratio : Float64
        getter soft_404_dominance_ratio : Float64
        getter sensitive_status_total : Int32
        getter sensitive_status_homogeneity_ratio : Float64
        getter sensitive_status_fingerprint_uniqueness_ratio : Float64
        getter context_sources_used : Array(String)
        getter context_sources_missing : Array(String)

        def initialize(
          @waf_likelihood_score, @waf_score_confidence, @redirect_cluster_dominance_ratio,
          @soft_404_dominance_ratio, @sensitive_status_total, @sensitive_status_homogeneity_ratio,
          @sensitive_status_fingerprint_uniqueness_ratio, @context_sources_used, @context_sources_missing,
        )
        end
      end

      def initialize(headers : Modules::Headers::Result?, crawler : Modules::Crawler::Result?)
        @total = 0
        @soft_matches = 0
        @redirect_total = 0
        @redirect_patterns = Hash(String, Int32).new(0)
        @redirect_max = 0
        @sensitive_total = 0
        @sensitive_counts = Hash(Int32, Int32).new(0)
        @sensitive_fingerprints = Hash(String, Int32).new(0)
        @hints = build_hints(headers, crawler)
        @sources_used = @hints.select { |_name, value| value }.keys
        @sources_missing = HINT_NAMES - @sources_used
        @snapshot = nil
      end

      @hints : Hash(String, Bool)
      @sources_used : Array(String)
      @sources_missing : Array(String)
      @snapshot : Snapshot?

      def update!(status : Int32, sample : Sample?, baseline : Baseline?) : Nil
        @total += 1
        @soft_matches += 1 if Confidence.soft_404_match_sample?(sample, baseline)
        update_redirect(status, sample)
        update_sensitive(status, sample)
        @snapshot = nil
      end

      def snapshot : Snapshot
        cached = @snapshot
        return cached unless cached.nil?

        redirect_cluster = ratio(@redirect_max, @redirect_total)
        soft_dominance = ratio(@soft_matches, @total)
        homogeneity = @sensitive_total > 0 ? ratio(@sensitive_counts.values.max? || 0, @sensitive_total) : 0.0
        uniqueness = @sensitive_total > 0 ? ratio(@sensitive_fingerprints.size, @sensitive_total) : 0.0
        snap = Snapshot.new(
          waf_likelihood_score(redirect_cluster, soft_dominance, homogeneity, uniqueness),
          waf_score_confidence, redirect_cluster, soft_dominance, @sensitive_total,
          homogeneity, uniqueness, @sources_used, @sources_missing,
        )
        @snapshot = snap
        snap
      end

      # Downgrades a decision that matches an anti-enumeration noise pattern.
      def adjust(decision : Decision, url : String, snap : Snapshot) : Decision
        return decision if decision.level == "low"
        return Decision.new("low", "waf_sensitive_status_homogeneity") if sensitive_noise?(decision, snap)
        return decision unless snap.waf_likelihood_score >= WAF_LIKELIHOOD_HIGH
        return Decision.new(downgrade(decision.level), "waf_redirect_cluster_dominance") if redirect_cluster_noise?(decision, snap, url)

        decision
      end

      private def update_redirect(status : Int32, sample : Sample?) : Nil
        return unless Fields.redirect_status?(status)

        @redirect_total += 1
        pattern = sample.try(&.redirect_pattern) || ""
        return if pattern.empty?

        count = (@redirect_patterns[pattern] += 1)
        @redirect_max = count if count > @redirect_max
      end

      private def update_sensitive(status : Int32, sample : Sample?) : Nil
        return unless SENSITIVE.includes?(status)

        @sensitive_total += 1
        @sensitive_counts[status] += 1
        fingerprint = sample.try(&.fingerprint) || ""
        @sensitive_fingerprints[fingerprint] += 1 unless fingerprint.empty?
      end

      private def waf_likelihood_score(redirect_cluster : Float64, soft_dominance : Float64, homogeneity : Float64, uniqueness : Float64) : Float64
        enrichment = @hints.values.count(true).to_f / Math.max(@hints.size, 1)
        score = (redirect_cluster * 0.35) + (soft_dominance * 0.30) + (homogeneity * 0.20) +
                ((1.0 - uniqueness) * 0.10) + (enrichment * 0.05)
        score.clamp(0.0, 1.0)
      end

      private def waf_score_confidence : String
        return "high" if @total >= 500
        return "medium" if @total >= 100

        "low"
      end

      private def sensitive_noise?(decision : Decision, snap : Snapshot) : Bool
        return false unless Confidence.sensitive_status_reason?(decision.reason)
        return false unless snap.sensitive_status_total >= SENSITIVE_NOISE_MIN_SAMPLES
        return true if snap.sensitive_status_homogeneity_ratio >= WAF_SENSITIVE_HOMOGENEITY &&
                       snap.sensitive_status_fingerprint_uniqueness_ratio <= WAF_SENSITIVE_UNIQUENESS_LOW

        snap.redirect_cluster_dominance_ratio >= SENSITIVE_NOISE_REDIRECT_DOMINANCE &&
          snap.sensitive_status_homogeneity_ratio >= WAF_SENSITIVE_HOMOGENEITY
      end

      private def redirect_cluster_noise?(decision : Decision, snap : Snapshot, url : String) : Bool
        decision.reason == "path_specific_redirect" &&
          snap.redirect_cluster_dominance_ratio >= WAF_REDIRECT_CLUSTER_DOMINANCE &&
          snap.soft_404_dominance_ratio >= SOFT_404_MIN_DOMINANCE_RATIO &&
          !Signals.high_signal_path?(path_of(url))
      end

      private def downgrade(level : String) : String
        level == "confirmed" ? "likely" : "low"
      end

      private def path_of(url : String) : String
        URI.parse(url).path.downcase
      rescue
        ""
      end

      private def ratio(numerator : Int32, denominator : Int32) : Float64
        denominator <= 0 ? 0.0 : numerator.to_f / denominator
      end

      private def build_hints(headers : Modules::Headers::Result?, crawler : Modules::Crawler::Result?) : Hash(String, Bool)
        {
          "headers_edge_hint"       => edge_header_hint?(headers),
          "crawler_blocked_hint"    => crawler_blocked_hint?(crawler),
          "crawler_low_unique_hint" => crawler_low_unique_hint?(crawler),
        }
      end

      private def edge_header_hint?(headers : Modules::Headers::Result?) : Bool
        return false if headers.nil?

        map = headers.headers
        server = (map["server"]? || "").downcase
        powered = (map["x-powered-by"]? || "").downcase
        challenge = (map["cf-mitigated"]? || "").downcase
        EDGE_VENDORS.any? { |vendor| server.includes?(vendor) } || powered.includes?("cloudflare") || challenge == "challenge"
      end

      private def crawler_blocked_hint?(crawler : Modules::Crawler::Result?) : Bool
        return false if crawler.nil?

        (crawler.error || "").matches?(CRAWLER_BLOCKED)
      end

      private def crawler_low_unique_hint?(crawler : Modules::Crawler::Result?) : Bool
        return false if crawler.nil?

        total = crawler.stats.total_unique || 0
        total > 0 && total < 20
      end
    end
  end
end
