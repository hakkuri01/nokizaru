# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'uri'
require_relative '../bb_live_target_suite'

class BBLiveTargetSuiteTest < Minitest::Test
  def test_targets_include_at_least_seventy_live_sites
    assert_operator BBLiveTargetSuite::TARGETS.length, :>=, 70
  end

  def test_targets_have_unique_target_keys
    keys = BBLiveTargetSuite::TARGETS.map { |target| BBLiveTargetSuite.target_key(target) }

    assert_equal keys.length, keys.uniq.length
  end

  def test_stable_tier_keys_are_known_targets
    all_keys = BBLiveTargetSuite::TARGETS.map { |target| BBLiveTargetSuite.target_key(target) }
    missing = BBLiveTargetSuite::STABLE_TARGET_KEYS - all_keys

    assert_empty missing
  end

  def test_canonical_profile_defaults_to_stable_tier
    suite = BBLiveTargetSuite.new(profile: 'canonical', dry_run: true)
    targets = suite.send(:selected_targets)

    assert_equal BBLiveTargetSuite::STABLE_TARGET_KEYS.length, targets.length
  end

  def test_fast_profile_defaults_to_full_tier
    suite = BBLiveTargetSuite.new(profile: 'fast', dry_run: true)
    targets = suite.send(:selected_targets)

    assert_equal BBLiveTargetSuite::TARGETS.length, targets.length
  end

  def test_targets_use_http_or_https
    invalid_targets = BBLiveTargetSuite::TARGETS.reject do |target|
      uri = URI.parse(target)
      %w[http https].include?(uri.scheme)
    rescue URI::InvalidURIError
      false
    end

    assert_empty invalid_targets
  end

  def test_build_command_profile_switches_cache_flag
    canonical = BBLiveTargetSuite.build_command(
      nokizaru_bin: '/tmp/nokizaru',
      target: 'https://github.com',
      out_dir: '/tmp/out',
      basename: 'run1',
      no_cache: true
    )
    fast = BBLiveTargetSuite.build_command(
      nokizaru_bin: '/tmp/nokizaru',
      target: 'https://github.com',
      out_dir: '/tmp/out',
      basename: 'run1',
      no_cache: false
    )

    assert_includes canonical, '--no-cache'
    refute_includes fast, '--no-cache'
  end

  def test_shard_targets_is_deterministic
    targets = [
      'https://github.com',
      'https://google.com',
      'https://cloudflare.com',
      'https://httpbin.org'
    ]

    shard_zero = BBLiveTargetSuite.shard_targets(targets, 2, 0)
    shard_one = BBLiveTargetSuite.shard_targets(targets, 2, 1)

    assert_equal 2, shard_zero.length
    assert_equal 2, shard_one.length
    assert_empty(shard_zero & shard_one)
    assert_equal(targets.sort_by do |target|
      BBLiveTargetSuite.target_key(target)
    end, (shard_zero + shard_one).sort_by do |target|
           BBLiveTargetSuite.target_key(target)
         end)
  end

  def test_adaptive_timeout_uses_baseline_p95
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 25.0,
        'elapsed_p95_s' => 40.0
      }
    }
    cfg = BBLiveTargetSuite::PROFILE_CONFIG['canonical']
    timeout = BBLiveTargetSuite.adaptive_timeout_for('github_com', cfg, baseline, 420)

    assert_equal 90, timeout
  end

  def test_verdict_non_strict_downgrades_regressions_to_warn
    targets = {
      'github_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 60.0,
        'elapsed_p95_s' => 62.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0
      }
    }
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0
      }
    }
    thresholds = BBLiveTargetSuite::PROFILE_CONFIG['fast'][:thresholds]

    verdict = BBLiveTargetSuite::Verdict.evaluate(targets, baseline, thresholds: thresholds, strict: false)
    assert_equal 'warn', verdict.dig('targets', 'github_com', 'status')
    assert_equal 1, verdict['warning_targets']
    assert_equal 0, verdict['failed_targets']
  end

  def test_verdict_non_strict_downgrades_low_success_rate_to_warn
    targets = {
      'github_com' => {
        'success_rate' => 0.5,
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 32.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0
      }
    }

    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0
      }
    }

    verdict = BBLiveTargetSuite::Verdict.evaluate(
      targets,
      baseline,
      thresholds: BBLiveTargetSuite::PROFILE_CONFIG['fast'][:thresholds],
      strict: false
    )

    assert_equal 'warn', verdict.dig('targets', 'github_com', 'status')
    assert_equal 'warn', verdict.dig('targets', 'github_com', 'speed_status')
  end

  def test_verdict_tracks_speed_and_quality_failures_separately
    targets = {
      'github_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 60.0,
        'elapsed_p95_s' => 62.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 50.0,
        'crawler_high_signal_count' => 10.0,
        'crawler_total_unique' => 30.0
      }
    }
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 40.0,
        'crawler_total_unique' => 100.0
      }
    }

    verdict = BBLiveTargetSuite::Verdict.evaluate(
      targets,
      baseline,
      thresholds: BBLiveTargetSuite::PROFILE_CONFIG['canonical'][:thresholds],
      strict: true
    )

    assert_equal 'fail', verdict.dig('targets', 'github_com', 'speed_status')
    assert_equal 'fail', verdict.dig('targets', 'github_com', 'quality_status')
    assert_operator verdict.dig('targets', 'github_com', 'balance', 'balanced_score'), :<, 100.0
    assert_equal 1, verdict['speed_failed_targets']
    assert_equal 1, verdict['quality_failed_targets']
  end

  def test_quality_score_drop_without_active_signal_drop_stays_pass
    targets = {
      'github_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 32.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 75.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0,
        'findings_count' => 40.0,
        'crawler_blocked' => 0.0
      }
    }
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0,
        'findings_count' => 40.0,
        'crawler_blocked' => 0.0
      }
    }

    verdict = BBLiveTargetSuite::Verdict.evaluate(
      targets,
      baseline,
      thresholds: BBLiveTargetSuite::PROFILE_CONFIG['canonical'][:thresholds],
      strict: true
    )

    assert_equal 'pass', verdict.dig('targets', 'github_com', 'quality_status')
  end

  def test_blocked_crawler_does_not_trigger_active_signal_quality_drops
    targets = {
      'github_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 32.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 90.0,
        'crawler_high_signal_count' => 0.0,
        'crawler_total_unique' => 0.0,
        'findings_count' => 40.0,
        'crawler_blocked' => 1.0
      }
    }
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0,
        'quality_score' => 100.0,
        'crawler_high_signal_count' => 50.0,
        'crawler_total_unique' => 100.0,
        'findings_count' => 40.0,
        'crawler_blocked' => 0.0
      }
    }

    verdict = BBLiveTargetSuite::Verdict.evaluate(
      targets,
      baseline,
      thresholds: BBLiveTargetSuite::PROFILE_CONFIG['canonical'][:thresholds],
      strict: true
    )

    assert_equal 'pass', verdict.dig('targets', 'github_com', 'quality_status')
  end

  def test_rolling_baseline_aggregates_recent_manifests
    Dir.mktmpdir do |dir|
      write_manifest(dir, 'bb_live_canonical_manifest_20260306T100000Z.json',
                     'github_com' => { 'elapsed_median_s' => 10.0, 'elapsed_p95_s' => 12.0 })
      write_manifest(dir, 'bb_live_canonical_manifest_20260306T101000Z.json',
                     'github_com' => { 'elapsed_median_s' => 12.0, 'elapsed_p95_s' => 14.0 })
      write_manifest(dir, 'bb_live_canonical_manifest_20260306T102000Z.json',
                     'github_com' => { 'elapsed_median_s' => 14.0, 'elapsed_p95_s' => 20.0 })

      baseline = BBLiveTargetSuite::RollingBaseline.load(out_dir: dir, profile: 'canonical', window: 2)

      assert_equal 2, baseline[:sample_count]
      assert_equal 13.0, baseline.dig(:baseline, 'github_com', 'elapsed_median_s')
      assert_equal 17.0, baseline.dig(:baseline, 'github_com', 'elapsed_p95_s')
    end
  end

  def test_baseline_snapshot_skips_failed_zero_rows
    snapshot = BBLiveTargetSuite::Baseline.snapshot_from_targets(
      'github_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 12.5,
        'elapsed_p95_s' => 14.0,
        'quality_score' => 95.0,
        'crawler_total_unique' => 120.0,
        'crawler_high_signal_count' => 30.0,
        'subdomain_count' => 12.0,
        'wayback_count' => 2.0,
        'crawler_blocked' => 0.0
      },
      'nike_com' => {
        'success_rate' => 0.0,
        'elapsed_median_s' => 0.0,
        'elapsed_p95_s' => 0.0,
        'quality_score' => 0.0,
        'crawler_total_unique' => 0.0,
        'crawler_high_signal_count' => 0.0,
        'subdomain_count' => 0.0,
        'wayback_count' => 0.0,
        'crawler_blocked' => 1.0
      }
    )

    assert_equal ['github_com'], snapshot.keys
    assert_equal 95.0, snapshot.dig('github_com', 'quality_score')
  end

  def test_baseline_write_merges_existing_profile_entries
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'baseline.json')
      File.write(path, JSON.pretty_generate('canonical' => {
                                              'github_com' => {
                                                'elapsed_median_s' => 10.0,
                                                'elapsed_p95_s' => 12.0,
                                                'quality_score' => 90.0
                                              }
                                            }))

      BBLiveTargetSuite::Baseline.write(path, 'canonical', {
                                          'google_com' => {
                                            'elapsed_median_s' => 11.0,
                                            'elapsed_p95_s' => 13.0,
                                            'quality_score' => 80.0
                                          }
                                        })

      payload = JSON.parse(File.read(path))
      assert_equal 10.0, payload.dig('canonical', 'github_com', 'elapsed_median_s')
      assert_equal 11.0, payload.dig('canonical', 'google_com', 'elapsed_median_s')
      assert_equal 90.0, payload.dig('canonical', 'github_com', 'quality_score')
      assert_equal 80.0, payload.dig('canonical', 'google_com', 'quality_score')
    end
  end

  def test_summary_surfaces_speed_quality_and_balance_columns
    manifest = {
      'generated_at' => '2026-03-15T00:00:00Z',
      'config' => { 'profile' => 'canonical', 'strict' => true, 'runs' => 1 },
      'targets' => {
        'github_com' => {
          'success_rate' => 1.0,
          'elapsed_median_s' => 30.0,
          'quality_score' => 120.0
        }
      },
      'verdict' => {
        'targets' => {
          'github_com' => {
            'status' => 'warn',
            'speed_status' => 'pass',
            'quality_status' => 'warn',
            'balance' => { 'balanced_score' => 88.0 },
            'reasons' => ['quality score drop 25.00% exceeds 20.00%']
          }
        },
        'passed_targets' => 0,
        'warning_targets' => 1,
        'failed_targets' => 0,
        'speed_failed_targets' => 0,
        'quality_failed_targets' => 0,
        'balanced_score_median' => 88.0
      }
    }

    summary = BBLiveTargetSuite::Summary.markdown(manifest)

    assert_includes summary,
                    '| Target | Success Rate | Median (s) | Quality | Balance | Speed | Quality | Verdict | Notes |'
    assert_includes summary, 'speed_fail=0 quality_fail=0 balance_median=88.00'
  end

  def test_verdict_includes_directory_outlier_diagnostics
    targets = {
      'cloudflare_com' => {
        'success_rate' => 1.0,
        'elapsed_median_s' => 50.0,
        'elapsed_p95_s' => 55.0,
        'elapsed_cv' => 0.1,
        'quality_score' => 300.0,
        'crawler_total_unique' => 2800.0,
        'crawler_high_signal_count' => 250.0,
        'directory_found_count' => 7800.0,
        'directory_prioritized_count' => 0.0,
        'directory_prioritized_ratio' => 0.0,
        'directory_low_confidence_ratio' => 1.0,
        'directory_soft_404_reason_ratio' => 1.0,
        'redirect_cluster_dominance_ratio' => 0.99,
        'waf_likelihood_score' => 0.95,
        'sensitive_status_promotion_ratio' => 0.8,
        'sensitive_status_unique_fingerprint_ratio' => 0.1,
        'wayback_count' => 0.0,
        'findings_count' => 5.0,
        'crawler_blocked' => 0.0
      }
    }
    baseline = {
      'cloudflare_com' => {
        'elapsed_median_s' => 45.0,
        'elapsed_p95_s' => 50.0,
        'quality_score' => 320.0,
        'crawler_total_unique' => 2800.0,
        'crawler_high_signal_count' => 250.0,
        'findings_count' => 5.0
      }
    }

    verdict = BBLiveTargetSuite::Verdict.evaluate(
      targets,
      baseline,
      thresholds: BBLiveTargetSuite::PROFILE_CONFIG['fast'][:thresholds],
      strict: false
    )

    diagnostics = verdict.dig('targets', 'cloudflare_com', 'diagnostics')
    assert_includes diagnostics, 'diag: directory candidates saturated with low prioritization ratio'
    assert_includes diagnostics, 'diag: soft-404 signature dominates directory confidence reasons'
    assert_includes diagnostics, 'diag: redirect cluster dominance suggests canonicalized/WAF-shaped responses'
    assert_includes diagnostics, 'diag: probable WAF-shaped response landscape'
    assert_includes diagnostics,
                    'diag: sensitive-status promotion likely over-triggered by uniform protection responses'
  end

  def test_discovery_metrics_include_directory_prioritization_signals
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sample.json')
      payload = {
        'modules' => {
          'crawler' => { 'stats' => { 'total_unique' => 10, 'high_signal_count' => 4 } },
          'subdomains' => { 'subdomains' => ['a.example.com'] },
          'wayback' => { 'urls' => ['https://example.com'] },
          'directory_enum' => {
            'found' => %w[/a /b /c /d],
            'prioritized_found' => %w[/a /b],
            'confirmed_found' => ['/a'],
            'low_confidence_found' => ['/c', '/d'],
            'stats' => {
              'total_requests' => 500,
              'confidence_reasons' => { 'soft_404_signature_match' => 2 },
              'waf_sensitive_promotion_count' => 1,
              'redirect_cluster_dominance_ratio' => 0.75,
              'waf_likelihood_score' => 0.6,
              'sensitive_status_fingerprint_uniqueness_ratio' => 0.3
            }
          }
        },
        'findings' => [{ 'title' => 'one' }]
      }
      File.write(path, JSON.pretty_generate(payload))

      metrics = BBLiveTargetSuite::DiscoveryMetrics.extract(path)
      assert_equal 4.0, metrics['directory_found_count']
      assert_equal 2.0, metrics['directory_prioritized_count']
      assert_equal 0.5, metrics['directory_prioritized_ratio']
      assert_equal 0.5, metrics['directory_low_confidence_ratio']
      assert_equal 0.25, metrics['directory_confirmed_ratio']
      assert_equal 0.5, metrics['directory_soft_404_reason_ratio']
      assert_equal 0.75, metrics['redirect_cluster_dominance_ratio']
      assert_equal 0.6, metrics['waf_likelihood_score']
      assert_equal 0.5, metrics['sensitive_status_promotion_ratio']
      assert_equal 0.3, metrics['sensitive_status_unique_fingerprint_ratio']
      assert_operator metrics['quality_score'], :>, 0.0
    end
  end

  def test_parse_options_defaults_to_rerunning_existing_outputs
    opts = parse_options([])
    assert_equal false, opts[:skip_existing]
  end

  private

  def write_manifest(dir, name, targets)
    payload = { 'targets' => targets }
    File.write(File.join(dir, name), JSON.pretty_generate(payload))
  end
end
