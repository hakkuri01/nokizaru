# frozen_string_literal: true

require_relative 'test_helper'

class WaybackNormalizeTest < Minitest::Test
  Normalize = Nokizaru::Modules::Wayback::Normalize

  def test_availability_fallback_ignores_root_only_snapshot
    snapshots = { 'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://www.google.com/' } }

    assert_empty Normalize.fallback_urls_from_availability(snapshots)
  end

  def test_availability_fallback_keeps_meaningful_snapshot_path
    snapshots = { 'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/admin' } }

    assert_equal ['https://example.com/admin'], Normalize.fallback_urls_from_availability(snapshots)
  end

  def test_archive_snapshot_extracts_original_url_and_rejects_non_archive_urls
    snapshot = 'https://web.archive.org/web/20240101000000/https://example.com/admin?x=1'

    assert_equal 'https://example.com/admin', Normalize.original_url_from_archive_snapshot(snapshot)
    assert_equal '', Normalize.original_url_from_archive_snapshot('https://example.com/web/20240101/https://evil.test')
  end

  def test_meaningful_archive_fallback_accepts_query_only_urls
    assert Normalize.meaningful_archive_fallback?('https://example.com/?q=admin')
    refute Normalize.meaningful_archive_fallback?('https://example.com/')
    refute Normalize.meaningful_archive_fallback?('not a url')
  end

  def test_sanitize_url_rejects_spaces_truncated_encoding_and_noisy_control_paths
    assert_equal '', Normalize.sanitize_url('https://example.com/a b')
    assert_equal '', Normalize.sanitize_url('https://example.com/%A')
    assert_equal '', Normalize.sanitize_url('https://example.com/%00')
    assert_equal 'https://example.com/admin', Normalize.sanitize_url('https://example.com/admin,')
  end

  def test_filter_urls_keeps_scope_dedupes_and_removes_low_signal_assets
    urls = [
      'https://example.com/admin',
      'https://cdn.example.com/image.png',
      'https://evil.test/admin',
      'https://example.com/admin'
    ]

    assert_equal ['https://example.com/admin'], Normalize.filter_urls(urls, target: 'https://www.example.com')
  end

  def test_rank_high_signal_urls_scores_and_limits_candidates
    urls = [
      'https://example.com/about',
      'https://example.com/admin/settings?tab=users',
      'https://example.com/api/v1/users',
      'https://example.com/admin/settings?tab=users'
    ]

    ranked = Normalize.rank_high_signal_urls(urls, limit: 2)

    assert_equal [
      'https://example.com/admin/settings?tab=users',
      'https://example.com/api/v1/users'
    ], ranked
  end

  def test_registrable_domain_falls_back_for_unknown_hosts
    assert_equal 'example.test', Normalize.registrable_domain('deep.example.test')
  end

  def test_scope_helpers_allow_same_registrable_domain_only
    scope = Normalize.target_scope('https://www.example.com/app')

    assert_equal 'example.com', scope
    assert Normalize.in_scope?('https://api.example.com/admin', scope)
    refute Normalize.in_scope?('https://example.net/admin', scope)
    refute Normalize.in_scope?('not a url', scope)
  end

  def test_low_signal_and_score_helpers_handle_assets_and_invalid_urls
    assert Normalize.low_signal_asset?('https://example.com/app.js')
    refute Normalize.low_signal_asset?('not a url')
    assert_operator Normalize.score_url('https://example.com/admin/settings?tab=users'), :>, 0
    assert_equal 0, Normalize.score_url('not a url')
  end
end
