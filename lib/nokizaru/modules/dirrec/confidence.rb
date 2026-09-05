# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Confidence
        private

        def soft_404_match_sample?(sample, baseline)
          return false unless valid_soft_404_sample?(sample, baseline)
          return redirect_soft_404_match?(sample, baseline) if redirect_status?(sample[:status])
          return false unless sample[:content_type] == baseline[:content_type]
          return true if fingerprint_match?(sample, baseline)

          title_and_length_match?(sample, baseline)
        end

        def valid_soft_404_sample?(sample, baseline)
          baseline && sample && sample[:status] == baseline[:status]
        end

        def redirect_soft_404_match?(sample, baseline)
          return sample[:redirect_pattern] == baseline[:redirect_pattern] if baseline[:redirect_pattern]
          return false unless baseline[:location]

          sample[:location] == baseline[:location]
        end

        def fingerprint_match?(sample, baseline)
          baseline_fingerprint = baseline[:fingerprint]
          sample_fingerprint = sample[:fingerprint]
          baseline_fingerprint && sample_fingerprint && baseline_fingerprint == sample_fingerprint
        end

        def title_and_length_match?(sample, baseline)
          length_delta = (sample[:body_length] - baseline[:body_length]).abs
          return false if length_delta > baseline[:tolerance]
          return true unless baseline[:title]

          sample[:title] == baseline[:title]
        end

        def finding_confidence(url, status, sample, baseline, normalized_target)
          return confidence_decision(:low, :soft_404_signature_match) if soft_404_match_sample?(sample, baseline)

          case status.to_i
          when 401, 403, 405, 500
            sensitive_status_confidence(url, sample, baseline, normalized_target, status.to_i)
          when 301, 302, 303, 307, 308
            redirect_confidence(url, sample, normalized_target)
          when 200, 204
            content_confidence(url, sample, baseline, normalized_target)
          else
            confidence_decision(:low, :non_actionable_status)
          end
        end

        def redirect_confidence(url, sample, normalized_target)
          path = response_path(url)
          return confidence_decision(:confirmed, :high_signal_path) if high_signal_path?(path)

          if sample.to_h[:redirect_pattern].to_s.start_with?('auth_entry:')
            return confidence_decision(:confirmed,
                                       :auth_redirect)
          end
          if generic_redirect_pattern?(sample.to_h[:redirect_pattern].to_s)
            return confidence_decision(:low,
                                       :generic_redirect_pattern)
          end
          return confidence_decision(:low, :target_root_redirect) if same_path_as_target?(path, normalized_target)

          confidence_decision(:likely, :path_specific_redirect)
        end

        def sensitive_status_confidence(url, sample, baseline, normalized_target, status)
          path = response_path(url)
          return confidence_decision(:confirmed, :high_signal_path) if high_signal_path?(path)
          if same_path_as_target?(path, normalized_target)
            return confidence_decision(:low, :target_root_sensitive_status)
          end
          return confidence_decision(:low, :baseline_like_response) if baseline_like_length?(sample, baseline)
          return confidence_decision(:likely, :meaningful_sensitive_status) if meaningful_body?(sample)
          if weak_sensitive_status_sample?(path, sample, status)
            return confidence_decision(:low, :weak_sensitive_status)
          end

          confidence_decision(:likely, :sensitive_status)
        end

        def content_confidence(url, sample, baseline, normalized_target)
          path = response_path(url)
          return confidence_decision(:low, :baseline_like_response) if baseline_like_length?(sample, baseline)
          return confidence_decision(:low, :not_found_title) if likely_not_found_title?(sample)

          if high_signal_path?(path) && meaningful_body?(sample)
            return confidence_decision(:confirmed,
                                       :high_signal_content)
          end
          return confidence_decision(:likely, :meaningful_content) if meaningful_body?(sample)
          if high_signal_path?(path) && !same_path_as_target?(path, normalized_target)
            return confidence_decision(:likely, :high_signal_path)
          end

          confidence_decision(:low, :low_information_response)
        end

        def confidence_decision(level, reason)
          {
            level: level.to_sym,
            reason: reason.to_s
          }
        end

        def sensitive_status_reason?(reason)
          %w[sensitive_status meaningful_sensitive_status].include?(reason.to_s)
        end

        def init_confidence_context(scan)
          {
            counters: {
              total_candidates: 0,
              soft_404_matches: 0,
              redirect_total: 0,
              redirect_patterns: Hash.new(0),
              sensitive_total: 0,
              sensitive_status_counts: Hash.new(0),
              sensitive_fingerprints: Hash.new(0)
            },
            enrichment: context_enrichment(scan),
            snapshot: nil
          }
        end

        def context_enrichment(scan)
          ctx = scan[:options][:ctx]
          modules = ctx.respond_to?(:run) ? ctx.run.fetch('modules', {}) : {}
          headers = modules['headers'].is_a?(Hash) ? modules['headers'] : {}
          crawler = modules['crawler'].is_a?(Hash) ? modules['crawler'] : {}

          hints = {
            headers_edge_hint: edge_header_hint?(headers),
            crawler_blocked_hint: crawler_blocked_hint?(crawler),
            crawler_low_unique_hint: crawler_low_unique_hint?(crawler)
          }

          {
            hints: hints,
            sources_used: hints.select { |_, value| value }.keys.map(&:to_s),
            sources_missing: %w[headers_edge_hint crawler_blocked_hint crawler_low_unique_hint] -
              hints.select { |_, value| value }.keys.map(&:to_s)
          }
        end

        def edge_header_hint?(headers_module)
          map = headers_module['headers'].is_a?(Hash) ? headers_module['headers'] : {}
          server = map['server'].to_s.downcase
          powered = map['x-powered-by'].to_s.downcase
          challenge = map['cf-mitigated'].to_s.downcase
          edge_vendor?(server) || powered.include?('cloudflare') || challenge == 'challenge'
        end

        def crawler_blocked_hint?(crawler_module)
          crawler_module['error'].to_s.match?(/HTTP status (403|405|429)\b/)
        end

        def crawler_low_unique_hint?(crawler_module)
          stats = crawler_module['stats'].is_a?(Hash) ? crawler_module['stats'] : {}
          stats['total_unique'].to_i.positive? && stats['total_unique'].to_i < 20
        end

        def update_confidence_context!(runtime, status, sample, baseline)
          ctx = runtime[:confidence_context]
          counters = ctx[:counters]
          counters[:total_candidates] += 1
          counters[:soft_404_matches] += 1 if soft_404_match_sample?(sample, baseline)

          update_redirect_context!(counters, status, sample)
          update_sensitive_status_context!(counters, status, sample)

          ctx[:snapshot] = nil
        end

        def update_redirect_context!(counters, status, sample)
          return unless redirect_status?(status)

          counters[:redirect_total] += 1
          pattern = sample.to_h[:redirect_pattern].to_s
          return if pattern.empty?

          counters[:redirect_patterns][pattern] += 1
        end

        def update_sensitive_status_context!(counters, status, sample)
          return unless [401, 403, 405, 500].include?(status.to_i)

          counters[:sensitive_total] += 1
          counters[:sensitive_status_counts][status.to_i] += 1
          fingerprint = sample.to_h[:fingerprint].to_s
          return if fingerprint.empty?

          counters[:sensitive_fingerprints][fingerprint] += 1
        end

        def confidence_context_snapshot(runtime)
          cached = runtime.dig(:confidence_context, :snapshot)
          return cached if cached

          ctx = runtime[:confidence_context]
          counters = ctx[:counters]
          enrichment = ctx[:enrichment]

          redirect_cluster = redirect_cluster_dominance_ratio(counters)
          soft_404_dominance = ratio(counters[:soft_404_matches], counters[:total_candidates])
          sensitive_homogeneity = sensitive_status_homogeneity_ratio(counters)
          sensitive_uniqueness = sensitive_status_fingerprint_uniqueness_ratio(counters)
          waf_score = waf_likelihood_score(
            redirect_cluster,
            soft_404_dominance,
            sensitive_homogeneity,
            sensitive_uniqueness,
            enrichment[:hints]
          )

          snapshot = {
            waf_likelihood_score: waf_score,
            waf_score_confidence: waf_score_confidence(counters[:total_candidates]),
            redirect_cluster_dominance_ratio: redirect_cluster,
            soft_404_dominance_ratio: soft_404_dominance,
            sensitive_status_total: counters[:sensitive_total].to_i,
            sensitive_status_homogeneity_ratio: sensitive_homogeneity,
            sensitive_status_fingerprint_uniqueness_ratio: sensitive_uniqueness,
            context_sources_used: enrichment[:sources_used],
            context_sources_missing: enrichment[:sources_missing]
          }

          runtime[:confidence_context][:snapshot] = snapshot
        end

        def redirect_cluster_dominance_ratio(counters)
          total = counters[:redirect_total].to_i
          return 0.0 if total <= 0

          max_cluster = counters[:redirect_patterns].values.max.to_i
          ratio(max_cluster, total)
        end

        def sensitive_status_homogeneity_ratio(counters)
          total = counters[:sensitive_total].to_i
          return 0.0 if total <= 0

          ratio(counters[:sensitive_status_counts].values.max.to_i, total)
        end

        def sensitive_status_fingerprint_uniqueness_ratio(counters)
          total = counters[:sensitive_total].to_i
          return 0.0 if total <= 0

          ratio(counters[:sensitive_fingerprints].keys.length, total)
        end

        def waf_likelihood_score(
          redirect_cluster, soft_404_dominance, sensitive_homogeneity, sensitive_uniqueness, hints
        )
          enrichment = hints.values.count(true).fdiv([hints.length, 1].max)
          score =
            (redirect_cluster * 0.35) +
            (soft_404_dominance * 0.30) +
            (sensitive_homogeneity * 0.20) +
            ((1.0 - sensitive_uniqueness) * 0.10) +
            (enrichment * 0.05)
          score.clamp(0.0, 1.0)
        end

        def waf_score_confidence(total_candidates)
          count = total_candidates.to_i
          return 'high' if count >= 500
          return 'medium' if count >= 100

          'low'
        end

        def ratio(numerator, denominator)
          return 0.0 if denominator.to_f <= 0.0

          numerator.to_f / denominator
        end

        def apply_waf_confidence_adjustment(decision, url, context)
          return decision if decision[:level].to_sym == :low

          if waf_sensitive_status_noise?(decision, context)
            return confidence_decision(:low, :waf_sensitive_status_homogeneity)
          end

          return decision unless context[:waf_likelihood_score].to_f >= WAF_LIKELIHOOD_HIGH

          if waf_redirect_cluster_noise?(decision, context, url)
            return confidence_decision(downgraded_confidence_level(decision[:level]), :waf_redirect_cluster_dominance)
          end

          decision
        end

        def waf_sensitive_status_noise?(decision, context)
          return false unless sensitive_status_reason?(decision[:reason])
          return false unless context[:sensitive_status_total].to_i >= SENSITIVE_NOISE_MIN_SAMPLES
          return true if context[:sensitive_status_homogeneity_ratio].to_f >= WAF_SENSITIVE_HOMOGENEITY &&
                         context[:sensitive_status_fingerprint_uniqueness_ratio].to_f <= WAF_SENSITIVE_UNIQUENESS_LOW

          context[:redirect_cluster_dominance_ratio].to_f >= SENSITIVE_NOISE_REDIRECT_DOMINANCE &&
            context[:sensitive_status_homogeneity_ratio].to_f >= WAF_SENSITIVE_HOMOGENEITY
        end

        def waf_redirect_cluster_noise?(decision, context, url)
          decision[:reason].to_s == 'path_specific_redirect' &&
            context[:redirect_cluster_dominance_ratio].to_f >= WAF_REDIRECT_CLUSTER_DOMINANCE &&
            context[:soft_404_dominance_ratio].to_f >= SOFT_404_MIN_DOMINANCE_RATIO &&
            !high_signal_path?(response_path(url))
        end

        def downgraded_confidence_level(level)
          case level.to_sym
          when :confirmed then :likely
          else :low
          end
        end

        def response_path(url)
          URI.parse(url.to_s).path.to_s.downcase
        rescue StandardError
          ''
        end

        def same_path_as_target?(path, normalized_target)
          return true if path.to_s.empty? || path == '/'

          target_path = URI.parse(normalized_target.to_s).path.to_s.downcase
          target_path = '/' if target_path.empty?
          normalize_pattern_path(path) == normalize_pattern_path(target_path)
        rescue StandardError
          false
        end

        def meaningful_body?(sample)
          payload = sample.to_h
          return false unless textual_content?(payload[:content_type])

          payload[:body_length].to_i > LOW_INFORMATION_BODY_BYTES
        end

        def textual_content?(content_type)
          type = content_type.to_s.downcase
          TEXTUAL_CONTENT_TYPES.any? { |token| type.start_with?(token) }
        end

        def baseline_like_length?(sample, baseline)
          return false unless sample && baseline
          return false unless sample[:content_type] == baseline[:content_type]

          tolerance = baseline[:tolerance].to_i
          return false unless tolerance.positive?

          (sample[:body_length].to_i - baseline[:body_length].to_i).abs <= [tolerance / 2, 64].max
        end

        def likely_not_found_title?(sample)
          title = sample.to_h[:title].to_s
          return false if title.empty?

          title.include?('not found') || title.include?('404')
        end

        def weak_sensitive_status_sample?(path, sample, status)
          return false unless [401, 403, 405, 500].include?(status.to_i)

          payload = sample.to_h
          generic_body = payload[:body_length].to_i <= (LOW_INFORMATION_BODY_BYTES * 2)
          generic_title = payload[:title].to_s.strip.empty?
          low_signal_segment = low_information_segment?(first_path_segment(path))
          generic_body && generic_title && low_signal_segment
        end
      end
    end
  end
end
