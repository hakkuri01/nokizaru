# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/comprehensive_suite'

class ComprehensiveSuiteTest < Minitest::Test
  def test_metrics_extract_reads_known_fields
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'run.json')
      File.write(path, JSON.pretty_generate(sample_run_payload))
      metrics = Bench::ComprehensiveSuite::Metrics.extract(path)

      assert_equal 12.4, metrics[:elapsed_s]
      assert_equal 33.3, metrics[:directory_requests_per_second]
      assert_equal 120, metrics[:directory_total_requests]
      assert_equal 2, metrics[:directory_errors]
      assert_equal 'seeded', metrics[:directory_mode]
      assert_equal 3, metrics[:directory_found_count]
      assert_equal 2, metrics[:directory_prioritized_count]
      assert_equal 41, metrics[:crawler_total_unique]
      assert_equal 18, metrics[:crawler_high_signal_count]
      assert_equal 3, metrics[:subdomains_count]
      assert_equal 2, metrics[:open_ports_count]
      assert_equal 2, metrics[:wayback_url_count]
      assert_equal 'found', metrics[:wayback_cdx_status]
      assert_equal 2, metrics[:findings_count]
    end
  end

  def test_stats_helpers_compute_median_and_p95
    values = [1.0, 2.0, 3.0, 8.0, 9.0]
    assert_equal 3.0, Bench::ComprehensiveSuite::Stats.median(values)
    assert_equal 9.0, Bench::ComprehensiveSuite::Stats.p95(values)
    assert_in_delta 0.7091, Bench::ComprehensiveSuite::Stats.coefficient_of_variation(values), 0.0001
  end

  def test_resource_metrics_extracts_marker_line
    output = "scan log line\n__NK_TIME__ RSS_KB=12345 USER_S=1.23 SYS_S=0.45\n"
    cleaned, resources = Bench::ComprehensiveSuite::ResourceMetrics.extract(output)

    assert_equal "scan log line\n", cleaned
    assert_equal 12_345, resources['max_rss_kb']
    assert_equal 1.23, resources['cpu_user_s']
    assert_equal 0.45, resources['cpu_system_s']
  end

  def test_verdict_fails_on_regression_when_strict
    profiles = {
      'lab_static' => {
        'success_rate' => 1.0,
        'floor_pass_rate' => 1.0,
        'elapsed_median_s' => 12.0,
        'elapsed_p95_s' => 14.0
      }
    }

    baseline = {
      'lab_static' => {
        'elapsed_median_s' => 8.0,
        'elapsed_p95_s' => 9.0
      }
    }

    verdict = Bench::ComprehensiveSuite::Verdict.evaluate(
      profiles,
      baseline,
      thresholds: {
        median_runtime_regression_pct: 20.0,
        p95_runtime_regression_pct: 25.0,
        min_success_rate: 1.0,
        max_elapsed_cv: 0.3
      },
      strict: true
    )

    assert_equal 1, verdict['failed_profiles']
    assert_equal 2, verdict['exit_code']
    assert_equal 'fail', verdict.dig('profiles', 'lab_static', 'status')
  end

  def test_verdict_warns_without_baseline
    profiles = {
      'live_github' => {
        'success_rate' => 1.0,
        'floor_pass_rate' => 1.0,
        'elapsed_median_s' => 20.0,
        'elapsed_p95_s' => 24.0
      }
    }

    verdict = Bench::ComprehensiveSuite::Verdict.evaluate(
      profiles,
      {},
      thresholds: {
        median_runtime_regression_pct: 35.0,
        p95_runtime_regression_pct: 45.0,
        min_success_rate: 0.75,
        max_elapsed_cv: 0.7
      },
      strict: false
    )

    assert_equal 1, verdict['warning_profiles']
    assert_equal 0, verdict['exit_code']
    assert_equal 'warn', verdict.dig('profiles', 'live_github', 'status')
  end

  def test_verdict_applies_profile_threshold_overrides
    profiles = {
      'lab_hostile' => {
        'success_rate' => 1.0,
        'floor_pass_rate' => 1.0,
        'elapsed_median_s' => 12.0,
        'elapsed_p95_s' => 14.0,
        'threshold_overrides' => {
          'median_runtime_regression_pct' => 60.0,
          'p95_runtime_regression_pct' => 80.0
        }
      }
    }

    baseline = {
      'lab_hostile' => {
        'elapsed_median_s' => 8.0,
        'elapsed_p95_s' => 9.0
      }
    }

    verdict = Bench::ComprehensiveSuite::Verdict.evaluate(
      profiles,
      baseline,
      thresholds: {
        median_runtime_regression_pct: 20.0,
        p95_runtime_regression_pct: 25.0,
        min_success_rate: 1.0,
        max_elapsed_cv: 0.3
      },
      strict: true
    )

    assert_equal 'pass', verdict.dig('profiles', 'lab_hostile', 'status')
  end

  def test_verdict_downgrades_regression_to_warn_when_non_strict
    profiles = {
      'live_github' => {
        'success_rate' => 1.0,
        'floor_pass_rate' => 1.0,
        'elapsed_median_s' => 40.0,
        'elapsed_p95_s' => 42.0,
        'elapsed_cv' => 0.1
      }
    }

    baseline = {
      'live_github' => {
        'elapsed_median_s' => 20.0,
        'elapsed_p95_s' => 25.0
      }
    }

    verdict = Bench::ComprehensiveSuite::Verdict.evaluate(
      profiles,
      baseline,
      thresholds: {
        median_runtime_regression_pct: 35.0,
        p95_runtime_regression_pct: 45.0,
        min_success_rate: 0.75,
        max_elapsed_cv: 0.7
      },
      strict: false
    )

    assert_equal 'warn', verdict.dig('profiles', 'live_github', 'status')
    assert_equal 1, verdict['warning_profiles']
  end

  def test_verdict_fails_when_variance_too_high
    profiles = {
      'lab_static' => {
        'success_rate' => 1.0,
        'floor_pass_rate' => 1.0,
        'elapsed_median_s' => 10.0,
        'elapsed_p95_s' => 15.0,
        'elapsed_cv' => 0.55
      }
    }

    verdict = Bench::ComprehensiveSuite::Verdict.evaluate(
      profiles,
      { 'lab_static' => { 'elapsed_median_s' => 10.0, 'elapsed_p95_s' => 15.0 } },
      thresholds: {
        median_runtime_regression_pct: 20.0,
        p95_runtime_regression_pct: 25.0,
        min_success_rate: 1.0,
        max_elapsed_cv: 0.3
      },
      strict: true
    )

    assert_equal 'fail', verdict.dig('profiles', 'lab_static', 'status')
  end

  def test_baseline_snapshot_and_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'baseline.json')
      snapshot = Bench::ComprehensiveSuite::Baseline.snapshot_from_profiles(
        'lab_static' => { 'elapsed_median_s' => 12.3456, 'elapsed_p95_s' => 19.8765 }
      )

      written = Bench::ComprehensiveSuite::Baseline.write(path, 'track_a', snapshot)
      payload = JSON.parse(File.read(path))

      assert_equal path, written
      assert_equal 12.3456, payload.dig('track_a', 'lab_static', 'elapsed_median_s')
      assert_equal 19.8765, payload.dig('track_a', 'lab_static', 'elapsed_p95_s')
    end
  end

  def test_rolling_baseline_uses_recent_manifests
    Dir.mktmpdir do |dir|
      write_manifest(dir, 'track_a_manifest_20260306T100000Z.json',
                     'lab_static' => { 'elapsed_median_s' => 10.0, 'elapsed_p95_s' => 12.0 })
      write_manifest(dir, 'track_a_manifest_20260306T101000Z.json',
                     'lab_static' => { 'elapsed_median_s' => 14.0, 'elapsed_p95_s' => 16.0 })
      write_manifest(dir, 'track_a_manifest_20260306T102000Z.json',
                     'lab_static' => { 'elapsed_median_s' => 18.0, 'elapsed_p95_s' => 20.0 })

      rolling = Bench::ComprehensiveSuite::RollingBaseline.load(
        out_dir: dir,
        track: 'track_a',
        window: 2
      )

      assert_equal 2, rolling[:sample_count]
      assert_equal 16.0, rolling.dig(:baseline, 'lab_static', 'elapsed_median_s')
      assert_equal 18.0, rolling.dig(:baseline, 'lab_static', 'elapsed_p95_s')
    end
  end

  def test_floor_check_supports_directory_confidence_metrics
    metrics = {
      directory_found_count: 2,
      directory_prioritized_count: 1
    }
    floors = {
      'directory_found_count' => 2,
      'directory_prioritized_count' => 1
    }

    result = Bench::ComprehensiveSuite::FloorCheck.check(metrics, floors)

    assert_equal true, result['passed']
    assert_equal true, result.dig('checks', 'directory_found_count', 'passed')
    assert_equal true, result.dig('checks', 'directory_prioritized_count', 'passed')
  end

  private

  def write_manifest(dir, name, profiles)
    payload = {
      'profiles' => profiles
    }
    File.write(File.join(dir, name), JSON.pretty_generate(payload))
  end

  def sample_run_payload
    {
      'meta' => { 'elapsed_s' => 12.4 },
      'modules' => {
        'directory_enum' => {
          'found' => %w[/a /b /c],
          'prioritized_found' => %w[/a /b],
          'stats' => {
            'requests_per_second' => 33.3,
            'total_requests' => 120,
            'errors' => 2,
            'mode' => 'seeded'
          }
        },
        'crawler' => {
          'stats' => {
            'total_unique' => 41,
            'high_signal_count' => 18
          }
        },
        'subdomains' => {
          'subdomains' => %w[a.example.com b.example.com c.example.com]
        },
        'portscan' => {
          'open_ports' => ['80 (HTTP)', '443 (HTTPS)']
        },
        'wayback' => {
          'urls' => ['https://example.com', 'https://example.com/login'],
          'cdx_status' => 'found'
        }
      },
      'findings' => [{ 'title' => 'A' }, { 'title' => 'B' }]
    }
  end
end
