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

    assert_equal 'https://example.com/admin?x=1', Normalize.original_url_from_archive_snapshot(snapshot)
    assert_equal 'https://example.com/admin?x=1',
                 Normalize.original_url_from_archive_snapshot(snapshot.sub('https://web.', 'http://web.'))
    assert_equal '', Normalize.original_url_from_archive_snapshot('https://example.com/web/20240101/https://evil.test')
  end

  def test_meaningful_archive_fallback_accepts_query_only_urls
    assert Normalize.meaningful_archive_fallback?('https://example.com/?q=admin')
    refute Normalize.meaningful_archive_fallback?('https://example.com/')
    refute Normalize.meaningful_archive_fallback?('not a url')
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

  def test_filter_preserves_code_documents_archives_and_raw_queries
    urls = %w[
      https://example.com/app.js?build=1
      https://example.com/report.pdf
      https://example.com/backup.zip
      https://example.com/config.xml
      https://example.com/image.png
      https://example.com/site.css
    ]

    assert_equal urls.first(4), Normalize.filter_urls(urls, target: 'https://example.com')
  end

  def test_url_validation_rejects_userinfo_controls_and_oversized_values
    refute Normalize.sanitized_url_record('https://user@example.com/admin')
    refute Normalize.sanitized_url_record("https://example.com/a\nadmin")
    refute Normalize.sanitized_url_record('https://example.com/%0aadmin')
    refute Normalize.sanitized_url_record("https://example.com/#{'a' * 8200}")
  end

  def test_triage_is_segment_aware_multi_label_and_counts_decoded_parameters
    urls = [
      'https://example.com/api/admin/app.js?return%5Fto=%2Fhome&id=1',
      'https://example.com/capistrano?userid=1',
      'https://example.com/.env?url=https%3A%2F%2Fexample.com'
    ]

    triage = Normalize.triage(urls)

    assert_includes triage['javascript_urls'], urls.first
    assert_includes triage['api_urls'], urls.first
    assert_includes triage['interesting_path_urls'], urls.first
    assert_includes triage['interesting_parameter_urls'], urls.first
    assert_includes triage['sensitive_file_urls'], urls.last
    refute_includes triage['interesting_path_urls'], urls[1]
    assert_equal({ 'id' => 1, 'return_to' => 1, 'url' => 1 }, triage['parameter_counts'])
    assert_equal urls.first, triage['review_urls'].first
  end

  def test_sensitive_file_recognizes_config_json
    assert Normalize.sensitive_file?('config.json')
  end

  def test_each_triage_category_has_a_hard_cap
    urls = Array.new(300) { |index| "https://example.com/api/#{index}.js?id=#{index}" }
    triage = Normalize.triage(urls)

    %w[review_urls javascript_urls api_urls interesting_parameter_urls].each do |category|
      assert_equal 250, triage[category].length
    end
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
  end
end
