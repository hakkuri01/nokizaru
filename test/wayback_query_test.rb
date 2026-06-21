# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body)

  def test_fetch_cdx_with_fallback_skips_reduced_query_after_staged_timeout_when_snapshot_exists
    snapshots = { 'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/login' } }
    reduced_called = false

    with_query_stub(:fetch_staged_cdx, [[], true]) do
      with_query_stub(:fetch_reduced_cdx, proc do
        reduced_called = true
        []
      end) do
        urls, status = Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, snapshots)

        assert_equal ['https://example.com/login'], urls
        assert_equal 'timeout_with_fallback', status
        refute reduced_called
      end
    end
  end

  def test_fetch_cdx_with_fallback_stops_staged_expansion_when_snapshot_exists
    snapshots = { 'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/login' } }
    observed_fallback = nil

    staged_stub = proc do |_target, _timeout_s, deadline_at: nil, fallback_available: false|
      _ = deadline_at
      observed_fallback = fallback_available
      [[], true]
    end

    with_query_stub(:fetch_staged_cdx, staged_stub) do
      urls, status = Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, snapshots)

      assert observed_fallback
      assert_equal ['https://example.com/login'], urls
      assert_equal 'timeout_with_fallback', status
    end
  end

  def test_fetch_staged_cdx_stops_after_first_timeout_when_fallback_available
    attempts = [
      [[], true],
      [['https://example.com/should-not-run'], false]
    ]

    with_query_stub(:fetch_urls_with_timeout, proc { attempts.shift }) do
      urls, timed_out = Wayback::Query.fetch_staged_cdx('https://example.com', 5.0, fallback_available: true)

      assert_empty urls
      assert timed_out
      assert_equal 1, attempts.length
    end
  end

  def test_fetch_cdx_with_fallback_uses_reduced_query_after_clean_empty_staged_response
    with_query_stub(:fetch_staged_cdx, [[], false]) do
      with_query_stub(:fetch_reduced_cdx, ['https://example.com/admin']) do
        urls, status = Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, nil)

        assert_equal ['https://example.com/admin'], urls
        assert_equal 'found_reduced', status
      end
    end
  end

  def test_fetch_cdx_with_fallback_uses_deadline_remaining_time_for_reduced_query
    observed_deadline = nil
    reduced_stub = proc do |_target, _timeout_s, deadline_at: nil|
      observed_deadline = deadline_at
      []
    end

    with_query_stub(:fetch_staged_cdx, [[], false]) do
      with_query_stub(:fetch_reduced_cdx, reduced_stub) do
        deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10.0

        Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, nil, deadline_at: deadline_at)

        assert_equal deadline_at, observed_deadline
      end
    end
  end

  def test_fetch_urls_deduplicates_cdx_lines_while_preserving_order
    body = "\nhttps://example.com/a\nhttps://example.com/b\nhttps://example.com/a\n  https://example.com/c  \n"

    with_http_stub(:get, FakeResponse.new(200, body)) do
      urls = Wayback::Query.fetch_urls({ 'url' => 'https://example.com/*' })

      assert_equal ['https://example.com/a', 'https://example.com/b', 'https://example.com/c'], urls
    end
  end

  def test_fetch_urls_with_status_merges_archive_source_records
    commoncrawl = [Wayback::Query.archive_record('https://example.com/admin', 'commoncrawl', '20240101000000')]
    virustotal = [Wayback::Query.archive_record('https://example.com/login', 'virustotal')]

    with_query_stub(:fetch_cdx_with_fallback, [['https://example.com/login'], 'found', []]) do
      with_archive_stub(:fetch_commoncrawl_records, commoncrawl) do
        with_archive_stub(:fetch_virustotal_records, virustotal) do
          urls, status, _reasons, records = Wayback::Query.fetch_urls_with_status('https://example.com', 5.0, nil)

          assert_equal ['https://example.com/login', 'https://example.com/admin'], urls
          assert_equal 'found', status
          sources = records.map { |record| record['source'] }
          assert_equal %w[wayback commoncrawl], sources
        end
      end
    end
  end

  def test_parse_commoncrawl_lines_returns_timestamped_records
    body = %({"url":"https://example.com/a","timestamp":"20240101000000"}\nnot-json\n)

    records = Wayback::ArchiveSources.parse_commoncrawl_lines(body)

    assert_equal 1, records.length
    assert_equal 'https://example.com/a', records.first['url']
    assert_equal 'commoncrawl', records.first['source']
    assert_equal '20240101000000', records.first['timestamp']
  end

  def test_build_cdx_payload_uses_host_pattern_without_scheme
    payload = Wayback::Query.build_cdx_payload('https://www.example.com/docs', limit: 50)

    assert_equal 'www.example.com/docs/*', payload['url']
    assert_equal 'statuscode:200', payload['filter']
    refute_includes payload.keys, 'collapse'
    refute_includes payload.keys, 'from'
    refute_includes payload.keys, 'to'
    refute_includes payload.keys, 'fastLatest'
  end

  def test_build_cdx_payload_can_request_collapse_for_expanded_attempts
    payload = Wayback::Query.build_cdx_payload('https://example.com', limit: 50, collapse: true)

    assert_equal 'urlkey', payload['collapse']
  end

  def test_build_cdx_payload_can_disable_status_filter_for_fallback_attempts
    payload = Wayback::Query.build_cdx_payload('https://example.com', limit: 50, status_filter: false)

    refute_includes payload.keys, 'filter'
  end

  def test_availability_timeout_reserves_cdx_budget
    assert_equal 12.0, Wayback::Query.availability_timeout(24.0)
    assert_equal 6.0, Wayback::Query.availability_timeout(4.0)
    assert_equal 12.0, Wayback::Query.cdx_timeout(24.0, 12.0)
  end

  def test_cdx_target_patterns_include_wildcard_root_and_host_fallbacks
    patterns = Wayback::Query.cdx_target_patterns('https://www.example.com/docs')

    assert_equal [
      'www.example.com/docs/*',
      'www.example.com/',
      'www.example.com',
      'example.com/docs/*',
      'example.com/',
      'example.com'
    ], patterns
  end

  def test_availability_variants_include_slash_scheme_and_www_forms
    variants = Wayback::Query.availability_variants('https://example.com')

    assert_equal [
      'https://example.com',
      'https://example.com/',
      'http://example.com/',
      'https://www.example.com/',
      'http://www.example.com/'
    ], variants
  end

  def test_archive_status_marks_service_errors_as_degraded
    availability = { state: :unknown, reason: 'service_unavailable' }

    assert_equal 'degraded', Wayback::Query.archive_status(availability, 'not_found', [])
    assert_equal 'degraded', Wayback::Query.archive_status({ state: :not_available }, 'archive_degraded', [])
  end

  def test_archive_status_marks_clean_empty_as_healthy
    availability = { state: :not_available, reason: nil }

    assert_equal 'healthy', Wayback::Query.archive_status(availability, 'not_found', [])
  end

  def test_manual_pivots_include_browser_and_api_links
    pivots = Wayback::Query.manual_pivots('https://example.com')

    assert_includes pivots['calendar_url'], 'https://web.archive.org/web/*/https://example.com'
    assert_includes pivots['availability_query_url'], 'archive.org/wayback/available?url=https%3A%2F%2Fexample.com'
    assert_includes pivots['cdx_query_url'], 'web.archive.org/cdx/search/cdx?'
  end

  def test_apply_availability_fallback_uses_snapshot_after_timeout
    snapshots = { 'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/admin' } }

    urls, status = Wayback::Query.apply_availability_fallback([], 'timeout', snapshots)

    assert_equal ['https://example.com/admin'], urls
    assert_equal 'timeout_with_fallback', status
  end

  def test_fetch_staged_cdx_deduplicates_across_attempts
    attempts = [
      [['https://example.com/a', 'https://example.com/b'], false],
      [['https://example.com/b', 'https://example.com/c'], false]
    ]

    with_query_stub(:fetch_urls_with_timeout, proc { attempts.shift }) do
      urls, timed_out = Wayback::Query.fetch_staged_cdx('https://example.com', 5.0)

      assert_equal ['https://example.com/a', 'https://example.com/b'], urls
      refute timed_out
    end
  end

  def test_fetch_staged_cdx_uses_second_attempt_only_when_first_is_empty
    attempts = [
      [[], false],
      [['https://example.com/recovered'], false]
    ]

    with_query_stub(:fetch_urls_with_timeout, proc { attempts.shift }) do
      urls, timed_out = Wayback::Query.fetch_staged_cdx('https://example.com', 5.0)

      assert_equal ['https://example.com/recovered'], urls
      refute timed_out
    end
  end

  private

  def with_query_stub(method_name, value)
    original = Wayback::Query.method(method_name)
    Wayback::Query.singleton_class.send(:define_method, method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end
    yield
  ensure
    Wayback::Query.singleton_class.send(:define_method, method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def with_http_stub(method_name, value)
    original = Wayback::HTTP.method(method_name)
    Wayback::HTTP.singleton_class.send(:define_method, method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end
    yield
  ensure
    Wayback::HTTP.singleton_class.send(:define_method, method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end

  def with_archive_stub(method_name, value)
    original = Wayback::ArchiveSources.method(method_name)
    Wayback::ArchiveSources.singleton_class.send(:define_method, method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end
    yield
  ensure
    Wayback::ArchiveSources.singleton_class.send(:define_method, method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
