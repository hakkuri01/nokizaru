# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body, :headers)

  def test_staged_cdx_uses_bounded_path_specific_plaintext_request
    payloads = []
    fetch = proc do |payload, _timeout, **|
      payloads << payload
      [['https://example.com/docs/admin'], false, nil]
    end

    Wayback::Query.stub(:fetch_urls_with_timeout, fetch) do
      urls, timed_out, reasons = Wayback::Query.fetch_staged_cdx('https://example.com/docs', 5.0)

      assert_equal ['https://example.com/docs/admin'], urls
      refute timed_out
      assert_empty reasons
    end

    assert_equal 1, payloads.length
    assert_equal 'example.com/docs/*', payloads.first['url']
    assert_equal 'original', payloads.first['fl']
    assert_equal '25', payloads.first['limit']
    refute_includes payloads.first, 'collapse'
    refute_includes payloads.first, 'filter'
    refute_includes payloads.first, 'output'
  end

  def test_staged_cdx_uses_path_specific_request_only_after_clean_empty
    payloads = []
    responses = [[[], false, nil], [['https://example.com/recovered'], false, nil]]
    fetch = proc do |payload, _timeout, **|
      payloads << payload
      responses.shift
    end

    Wayback::Query.stub(:fetch_urls_with_timeout, fetch) do
      urls, timed_out, = Wayback::Query.fetch_staged_cdx('https://example.com/docs', 5.0)

      assert_equal ['https://example.com/recovered'], urls
      refute timed_out
    end

    patterns = payloads.map { |payload| payload['url'] }

    assert_equal ['example.com/docs/*', 'example.com/'], patterns
    assert_nil payloads.first['filter']
    assert_equal 'statuscode:200', payloads.last['filter']
  end

  def test_snapshot_fallback_stops_after_source_timeout
    snapshots = {
      'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/login' }
    }
    reduced_called = false

    Wayback::Query.stub(:fetch_staged_cdx, [[], true, ['timeout']]) do
      Wayback::Query.stub(:fetch_reduced_cdx, proc { reduced_called = true }) do
        urls, status, reasons = Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, snapshots)

        assert_equal ['https://example.com/login'], urls
        assert_equal 'timeout_with_fallback', status
        assert_equal ['timeout'], reasons
        refute reduced_called
      end
    end
  end

  def test_clean_empty_staged_requests_use_reduced_query
    Wayback::Query.stub(:fetch_staged_cdx, [[], false, []]) do
      Wayback::Query.stub(:fetch_reduced_cdx, ['https://example.com/admin']) do
        urls, status, reasons = Wayback::Query.fetch_cdx_with_fallback('https://example.com', 3.0, nil)

        assert_equal ['https://example.com/admin'], urls
        assert_equal 'found_reduced', status
        assert_empty reasons
      end
    end
  end

  def test_primary_source_timeout_is_classified_without_changing_staged_requests
    payloads = []
    request = proc do |uri, **|
      payloads << URI.decode_www_form(uri.query).to_h
      raise Timeout::Error, 'source deadline'
    end

    Wayback::HTTP.stub(:request, request) do
      urls, timed_out, reasons = Wayback::Query.fetch_staged_cdx('https://example.com/docs', 5.0)

      assert_empty urls
      refute timed_out
      assert_equal %w[timeout timeout], reasons
    end

    patterns = payloads.map { |payload| payload['url'] }

    assert_equal ['example.com/docs/*', 'example.com/'], patterns
  end

  def test_fetch_urls_with_timeout_classifies_direct_timeout_without_propagating
    Wayback::HTTP.stub(:get, ->(*) { raise Timeout::Error, 'source deadline' }) do
      urls, timed_out, reason = Wayback::Query.fetch_urls_with_timeout({ 'url' => 'example.com/*' }, 1.0)

      assert_empty urls
      refute timed_out
      assert_equal 'timeout', reason
    end
  end

  def test_cdx_success_still_merges_alternate_sources
    common_crawl = [Wayback::Query.archive_record('https://example.com/admin', 'commoncrawl', '20240101')]
    external = [common_crawl, {
      'common_crawl' => Wayback::Query.source_health('found', records: 1),
      'virustotal' => Wayback::Query.source_health('skipped', reason: 'missing_api_key')
    }]
    availability = { state: :not_available, snapshots: nil, reason: nil }

    Wayback::Query.stub(:fetch_cdx_with_fallback, [['https://example.com/login'], 'found', []]) do
      Wayback::ArchiveSources.stub(:fetch_records, external) do
        urls, status, _, records, found_availability, health =
          Wayback::Query.fetch_urls_with_status('https://example.com', 5.0, nil, availability: availability)

        assert_equal ['https://example.com/login', 'https://example.com/admin'], urls
        assert_equal 'found', status
        sources = records.map { |record| record['source'] }

        assert_equal %w[wayback commoncrawl], sources
        assert_equal :not_available, found_availability[:state]
        assert_equal 'found', health.dig('common_crawl', 'status')
      end
    end
  end

  def test_availability_fallback_retains_provenance_when_other_sources_fail
    snapshots = {
      'closest' => { 'url' => 'https://web.archive.org/web/20240101000000/https://example.com/login' }
    }
    external = [[], {
      'common_crawl' => Wayback::Query.source_health('timeout', reason: 'timeout'),
      'virustotal' => Wayback::Query.source_health('skipped', reason: 'missing_api_key')
    }]

    cdx_result = [['https://example.com/login'], 'timeout_with_fallback', ['timeout']]
    Wayback::Query.stub(:fetch_cdx_with_fallback, cdx_result) do
      Wayback::ArchiveSources.stub(:fetch_records, external) do
        availability = { state: :available, snapshots: snapshots, reason: nil }
        urls, status, _, records, _, health = Wayback::Query.fetch_urls_with_status(
          'https://example.com', 5.0, snapshots, availability: availability
        )

        assert_equal ['https://example.com/login'], urls
        assert_equal 'timeout_with_fallback', status
        assert_equal ['availability'], records.first['sources']
        assert_equal 'timeout', health.dig('cdx', 'status')
      end
    end
  end

  def test_common_crawl_timeout_is_source_local
    Wayback::HTTP.stub(:request, ->(*) { raise Timeout::Error, 'source deadline' }) do
      records, health = Wayback::ArchiveSources.fetch_commoncrawl_records('https://example.com', 1.0)

      assert_empty records
      assert_equal 'timeout', health['status']
      assert_equal 'timeout', health['reason']
    end
  end

  def test_virustotal_timeout_is_source_local
    Nokizaru::KeyStore.stub(:fetch, 'key') do
      Wayback::HTTP.stub(:request, ->(*) { raise Timeout::Error, 'source deadline' }) do
        records, health = Wayback::ArchiveSources.fetch_virustotal_records('https://example.com', 1.0)

        assert_empty records
        assert_equal 'timeout', health['status']
      end
    end
  end

  def test_common_crawl_preserves_head_query_shape_and_upstream_status
    responses = [
      FakeResponse.new(200, '[{"cdx-api":"https://index.commoncrawl.org/cdx"}]', {}),
      FakeResponse.new(403, 'restricted', {})
    ]
    requested_uri = nil
    request = proc do |uri, **_kwargs|
      requested_uri = uri if uri.host == 'index.commoncrawl.org' && uri.path == '/cdx'
      responses.shift
    end

    Wayback::HTTP.stub(:get, request) do
      records, health = Wayback::ArchiveSources.fetch_commoncrawl_records('https://example.com', 2.0)

      assert_empty records
      assert_equal 'failed', health['status']
      assert_equal 'http_403', health['reason']
      refute_includes health, 'limit'
      assert_includes requested_uri.query, 'fl=url%2Ctimestamp'
      refute_includes requested_uri.query, 'limit='
    end
  end

  def test_virustotal_without_key_is_skipped
    Nokizaru::KeyStore.stub(:fetch, nil) do
      records, health = Wayback::ArchiveSources.fetch_virustotal_records('https://example.com', 2.0)

      assert_empty records
      assert_equal 'skipped', health['status']
      assert_equal 'missing_api_key', health['reason']
    end
  end

  def test_fetch_urls_deduplicates_plaintext_while_preserving_order
    body = "\nhttps://example.com/a\nhttps://example.com/b\nhttps://example.com/a\n"

    Wayback::HTTP.stub(:get, FakeResponse.new(200, body, {})) do
      assert_equal ['https://example.com/a', 'https://example.com/b'],
                   Wayback::Query.fetch_urls({ 'url' => 'https://example.com/*' })
    end
  end

  def test_build_cdx_payload_preserves_path_and_supports_optional_collapse
    payload = Wayback::Query.build_cdx_payload('https://www.example.com/docs', limit: 50)
    collapsed = Wayback::Query.build_cdx_payload('https://example.com', limit: 50, collapse: true)

    assert_equal 'www.example.com/docs/*', payload['url']
    assert_equal 'original', payload['fl']
    assert_equal 'statuscode:200', payload['filter']
    refute_includes payload, 'collapse'
    assert_equal 'urlkey', collapsed['collapse']
  end

  def test_availability_variants_and_timeout_budget_match_proven_flow
    assert_equal [
      'https://example.com', 'https://example.com/', 'http://example.com/',
      'https://www.example.com/', 'http://www.example.com/'
    ], Wayback::Query.availability_variants('https://example.com')
    assert_in_delta 12.0, Wayback::Query.availability_timeout(24.0)
    assert_in_delta 12.0, Wayback::Query.cdx_timeout(24.0, 12.0)
  end

  def test_duplicate_records_merge_sources_and_observations
    records = [
      Wayback::Query.archive_record('https://example.com/api', 'wayback', '20240101'),
      Wayback::Query.archive_record('https://example.com/api', 'commoncrawl', '20240202')
    ]

    merged = Wayback::ArchiveSources.dedupe_records(records).first

    assert_equal %w[wayback commoncrawl], merged['sources']
    assert_equal 2, merged['observations'].length
    assert_equal %w[source timestamp], merged['observations'].first.keys
  end

  def test_common_crawl_rejects_untrusted_index_endpoints
    refute Wayback::ArchiveSources.valid_commoncrawl_endpoint?('http://index.commoncrawl.org/cdx')
    refute Wayback::ArchiveSources.valid_commoncrawl_endpoint?('https://user@index.commoncrawl.org/cdx')
    refute Wayback::ArchiveSources.valid_commoncrawl_endpoint?('https://index.commoncrawl.org.evil.test/cdx')
    assert Wayback::ArchiveSources.valid_commoncrawl_endpoint?('https://index.commoncrawl.org/CC-MAIN-index')
  end
end
