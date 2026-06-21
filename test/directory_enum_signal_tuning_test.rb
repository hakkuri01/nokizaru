# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumSignalTuningTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_crawler_high_signal_urls_are_seeded_before_broad_crawler_urls
    ctx = Struct.new(:run).new(
      {
        'artifacts' => {},
        'modules' => {
          'crawler' => {
            'high_signal_urls' => ['https://example.com/admin/console'],
            'internal_links' => ['https://example.com/catalog']
          }
        }
      }
    )

    plan = DirectoryEnum.build_scan_plan(target: 'https://example.com', words: ['login'], filext: '', ctx: ctx)

    assert_operator plan[:seed_urls].index('https://example.com/admin/console'), :<,
                    plan[:seed_urls].index('https://example.com/catalog')
  end

  def test_sensitive_status_noise_demotes_without_high_composite_waf_score
    adjusted = DirectoryEnum.apply_waf_confidence_adjustment(
      { level: :likely, reason: 'meaningful_sensitive_status' },
      403,
      {},
      'https://example.com/admin',
      'https://example.com',
      noisy_sensitive_context
    )

    assert_equal :low, adjusted[:level]
    assert_equal 'waf_sensitive_status_homogeneity', adjusted[:reason]
  end

  def test_display_stop_reason_simplifies_marginal_value_details
    reason = 'marginal directory value collapsed under dominant target shape ' \
             '(wildcard=false, redirect_cluster=true, low_confidence_ratio=0.96)'

    assert_equal 'Uniform redirects or soft-404s detected', DirectoryEnum.display_stop_reason(reason)
  end

  def test_display_stop_reason_simplifies_hostile_transport_details
    reason = 'sustained hostile transport failures with no useful signal (requests=320, success=0, errors=320)'

    assert_equal 'Hostile transport failures limited reliable checks', DirectoryEnum.display_stop_reason(reason)
  end

  def test_display_stop_reason_simplifies_hostile_pressure_details
    reason = 'sustained hostile pressure with low prioritized yield (pressure_streak=4, low_yield_streak=5)'

    assert_equal 'Hostile pressure with low reliable yield', DirectoryEnum.display_stop_reason(reason)
  end

  def test_display_stop_reason_simplifies_budget_and_stall_details
    assert_equal 'Request limit reached', DirectoryEnum.display_stop_reason('request budget hit (1800/1800)')
    assert_equal 'Time limit reached', DirectoryEnum.display_stop_reason('time budget hit (180.0s/180.0s)')
    assert_equal 'Responses stalled', DirectoryEnum.display_stop_reason('scan stalled after 30.0s idle')
  end

  def test_dir_stats_preserve_technical_and_display_stop_reasons
    stats = DirectoryEnum.init_stats
    stop_meta = {
      mode: 'seeded',
      reason: 'request budget hit (1800/1800)',
      display_reason: 'Request limit reached',
      preflight: {},
      budgets: {}
    }

    result = DirectoryEnum.dir_stats(stats, stop_meta, 1.0, 1.0)

    assert_equal 'request budget hit (1800/1800)', result['stop_reason']
    assert_equal 'Request limit reached', result['stop_reason_display']
  end

  private

  def noisy_sensitive_context
    {
      waf_likelihood_score: 0.4,
      sensitive_status_total: 80,
      sensitive_status_homogeneity_ratio: 1.0,
      sensitive_status_fingerprint_uniqueness_ratio: 0.01,
      redirect_cluster_dominance_ratio: 0.5
    }
  end
end
