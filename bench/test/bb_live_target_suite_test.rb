# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../bb_live_target_suite'

class BBLiveTargetSuiteTest < Minitest::Test
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
        'elapsed_cv' => 0.1
      }
    }
    baseline = {
      'github_com' => {
        'elapsed_median_s' => 30.0,
        'elapsed_p95_s' => 35.0
      }
    }
    thresholds = BBLiveTargetSuite::PROFILE_CONFIG['fast'][:thresholds]

    verdict = BBLiveTargetSuite::Verdict.evaluate(targets, baseline, thresholds: thresholds, strict: false)
    assert_equal 'warn', verdict.dig('targets', 'github_com', 'status')
    assert_equal 1, verdict['warning_targets']
    assert_equal 0, verdict['failed_targets']
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

  private

  def write_manifest(dir, name, targets)
    payload = { 'targets' => targets }
    File.write(File.join(dir, name), JSON.pretty_generate(payload))
  end
end
