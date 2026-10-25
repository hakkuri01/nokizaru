require "../finding"
require "../modules/dirrec"
require "../modules/headers"

module Nokizaru
  module Findings
    # Confidently NAMES the adversarial shape a directory scan ran into, so the
    # operator gets an actionable conclusion instead of a silent gap. The shape is
    # read from the dominant response class (which status the server returned to
    # the overwhelming majority of probes) crossed with the scan's own dominance
    # and WAF-likelihood signals: a block code (403/406) under an edge fingerprint
    # is a WAF, 429/503 is rate-limiting, an identical 200 is a soft-404 wildcard,
    # a redirect cluster is an auth wall. A benign site that merely 404s a lot is
    # NOT flagged (404 is an honest answer, not a wall). Stage 4 (adaptation
    # persistence) will enrich these findings with what the scan tried before it
    # gave up. Complexity: O(status classes) over the bounded by_status map.
    module AdversaryRules
      extend self

      MIN_SAMPLE        =  40
      DOMINANT_SHARE    = 0.9
      EDGE_VENDORS      = {"cloudflare" => "Cloudflare", "cf-ray" => "Cloudflare", "akamai" => "Akamai", "sucuri" => "Sucuri", "imperva" => "Imperva", "incapsula" => "Imperva Incapsula", "fastly" => "Fastly", "awswaf" => "AWS WAF"}
      WAF_STATUSES      = {403, 406}
      THROTTLE_STATUSES = {429, 503}
      REDIRECT_STATUSES = {301, 302, 303, 307, 308}

      def call(dir : Modules::DirectoryEnum::Result?, headers : Modules::Headers::Result? = nil) : Array(Finding)
        return [] of Finding if dir.nil?

        dominant = dominant_response(dir.by_status)
        return [] of Finding if dominant.nil?

        status, share, total = dominant
        finding = classify(status, share, total, dir.stats, headers)
        finding.nil? ? [] of Finding : [finding]
      end

      private def dominant_response(by_status : Hash(String, Array(String))) : {Int32, Float64, Int32}?
        counts = by_status.compact_map { |code, urls| code.to_i?.try { |status| {status, urls.size} } }
        total = counts.sum { |(_status, count)| count }
        return nil if total < MIN_SAMPLE

        top = counts.max_by? { |(_status, count)| count }
        return nil if top.nil?

        share = top[1] / total.to_f
        share >= DOMINANT_SHARE ? {top[0], share, total} : nil
      end

      private def classify(status : Int32, share : Float64, total : Int32, stats : DirRec::Stats, headers : Modules::Headers::Result?) : Finding?
        if WAF_STATUSES.includes?(status) && waf_like?(stats, headers)
          waf_finding(status, share, total, stats, headers)
        elsif THROTTLE_STATUSES.includes?(status)
          throttle_finding(status, share, total, stats)
        elsif status == 200 && stats.soft_404_dominance_ratio >= DOMINANT_SHARE
          soft_404_finding(share, total, stats)
        elsif REDIRECT_STATUSES.includes?(status) && stats.redirect_cluster_dominance_ratio >= DOMINANT_SHARE
          auth_wall_finding(status, share, total)
        end
      end

      private def waf_like?(stats : DirRec::Stats, headers : Modules::Headers::Result?) : Bool
        stats.waf_likelihood_score >= 0.5 ||
          stats.sensitive_status_homogeneity_ratio >= 0.8 ||
          !edge_vendor(headers).nil?
      end

      private def waf_finding(status : Int32, share : Float64, total : Int32, stats : DirRec::Stats, headers : Modules::Headers::Result?) : Finding
        vendor = edge_vendor(headers)
        name = vendor || "A web application firewall"
        Finding.new(
          id: "dir.waf_detected",
          severity: "medium",
          title: vendor ? "#{vendor} WAF blocking directory enumeration" : "Web application firewall blocking directory enumeration",
          source_module: "directory_enum",
          tags: ["adversarial", "waf", "recon"],
          evidence: "#{name} returned HTTP #{status} to #{percent(share)} of #{total} directory probes.",
          recommendation: "#{adaptation_clause(stats)}Automated path enumeration is unreliable behind this WAF. Test from an allowlisted or authenticated origin, or review the confirmed findings and crawler/wayback-derived paths manually.",
        )
      end

      private def throttle_finding(status : Int32, share : Float64, total : Int32, stats : DirRec::Stats) : Finding
        Finding.new(
          id: "dir.rate_limited",
          severity: "medium",
          title: "Server rate-limiting directory enumeration",
          source_module: "directory_enum",
          tags: ["adversarial", "rate-limit", "recon"],
          evidence: "HTTP #{status} answered #{percent(share)} of #{total} directory probes.",
          recommendation: "#{adaptation_clause(stats)}Results are incomplete. Lower the request rate or use authenticated access, then re-run enumeration against the confirmed surface.",
        )
      end

      # The adaptation narrative, when the scan tried to adapt and the adversary
      # persisted: this is the actionable half (what was tried, that it failed).
      private def adaptation_clause(stats : DirRec::Stats) : String
        return "" unless stats.adversary_persisted?

        note = stats.adversary_adaptation
        note.nil? ? "" : "The scan #{note}, and the wall persisted, so enumeration was stopped early. "
      end

      private def soft_404_finding(share : Float64, total : Int32, stats : DirRec::Stats) : Finding
        Finding.new(
          id: "dir.soft_404_wildcard",
          severity: "low",
          title: "Soft-404 wildcard (catch-all) responses",
          source_module: "directory_enum",
          tags: ["adversarial", "soft-404", "recon"],
          evidence: "The server answered HTTP 200 for #{percent(share)} of #{total} probes, including paths that do not exist.",
          recommendation: "#{adaptation_clause(stats)}Status-based path discovery is unreliable here (likely a SPA or catch-all). Trust the crawler, JS routes, and wayback-derived paths plus the confirmed findings over brute force.",
        )
      end

      private def auth_wall_finding(status : Int32, share : Float64, total : Int32) : Finding
        Finding.new(
          id: "dir.auth_wall",
          severity: "low",
          title: "Authentication wall redirecting directory enumeration",
          source_module: "directory_enum",
          tags: ["adversarial", "auth", "recon"],
          evidence: "HTTP #{status} redirected #{percent(share)} of #{total} directory probes to a single location.",
          recommendation: "The surface is gated behind authentication. Enumerate with a valid session, or focus on the confirmed unauthenticated findings.",
        )
      end

      private def edge_vendor(headers : Modules::Headers::Result?) : String?
        return nil if headers.nil?

        blob = headers.headers.flat_map { |name, value| [name, value] }.join(' ').downcase
        EDGE_VENDORS.each { |needle, vendor| return vendor if blob.includes?(needle) }
        nil
      end

      private def percent(share : Float64) : String
        "#{(share * 100).round(1)}%"
      end
    end
  end
end
