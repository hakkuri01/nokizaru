# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumWafConfidenceTest < Minitest::Test
  def test_apply_waf_confidence_adjustment_downgrades_uniform_sensitive_status
    decision = { level: :likely, reason: 'meaningful_sensitive_status' }
    context = {
      waf_likelihood_score: 0.9,
      redirect_cluster_dominance_ratio: 0.9,
      soft_404_dominance_ratio: 0.9,
      sensitive_status_homogeneity_ratio: 0.95,
      sensitive_status_fingerprint_uniqueness_ratio: 0.05
    }

    adjusted = Nokizaru::Modules::DirectoryEnum.send(
      :apply_waf_confidence_adjustment,
      decision,
      403,
      {},
      'https://example.com/random',
      'https://example.com',
      context
    )

    assert_equal :low, adjusted[:level]
    assert_equal 'waf_sensitive_status_homogeneity', adjusted[:reason]
  end

  def test_apply_waf_confidence_adjustment_preserves_decision_when_waf_score_low
    decision = { level: :likely, reason: 'meaningful_sensitive_status' }
    context = {
      waf_likelihood_score: 0.2,
      redirect_cluster_dominance_ratio: 0.9,
      soft_404_dominance_ratio: 0.9,
      sensitive_status_homogeneity_ratio: 0.95,
      sensitive_status_fingerprint_uniqueness_ratio: 0.05
    }

    adjusted = Nokizaru::Modules::DirectoryEnum.send(
      :apply_waf_confidence_adjustment,
      decision,
      403,
      {},
      'https://example.com/random',
      'https://example.com',
      context
    )

    assert_equal :likely, adjusted[:level]
    assert_equal 'meaningful_sensitive_status', adjusted[:reason]
  end

  def test_confidence_context_snapshot_works_without_other_modules
    runtime = {
      confidence_context: {
        counters: {
          total_candidates: 10,
          soft_404_matches: 9,
          redirect_total: 9,
          redirect_patterns: { 'same' => 9 },
          sensitive_total: 3,
          sensitive_status_counts: { 403 => 3 },
          sensitive_fingerprints: { 'fp1' => 3 }
        },
        enrichment: {
          hints: {
            headers_edge_hint: false,
            crawler_blocked_hint: false,
            crawler_low_unique_hint: false,
            wayback_heavy_hint: false
          },
          sources_used: [],
          sources_missing: %w[headers_edge_hint crawler_blocked_hint crawler_low_unique_hint wayback_heavy_hint]
        },
        snapshot: nil
      }
    }

    snapshot = Nokizaru::Modules::DirectoryEnum.send(:confidence_context_snapshot, runtime)

    assert_operator snapshot[:waf_likelihood_score], :>, 0.75
    assert_equal 'low', snapshot[:waf_score_confidence]
  end
end
