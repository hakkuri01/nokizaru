# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body, :headers)

  def test_history_payload_is_exact_host_and_requests_change_fields
    payload = Wayback::CDX.build_payload('https://app.example.com/docs', collapse: 'digest')

    assert_equal 'app.example.com/', payload['url']
    assert_equal 'host', payload['matchType']
    assert_equal 'timestamp,original,mimetype,statuscode,digest', payload['fl']
    assert_equal 'digest', payload['collapse']
    assert_equal 'true', payload['showResumeKey']
    assert_includes payload['filter'], 'app\\.example\\.com'
  end

  def test_parse_cdx_page_extracts_rows_and_resume_key
    body = JSON.generate([
                           %w[timestamp original mimetype statuscode digest],
                           %w[20240102030405 https://example.com/admin text/html 200 first],
                           [], ['resume-token']
                         ])

    rows, resume_key, reason = Wayback::CDX.parse_page(body)

    assert_nil reason
    assert_equal 'resume-token', resume_key
    assert_equal 'https://example.com/admin', rows.first['original']
    assert_equal 'first', rows.first['digest']
  end

  def test_fetch_history_follows_resume_keys_and_keeps_exact_host_only
    pages = [
      [[cdx_row('https://example.com/admin', '20240102030405', 'one')], 'next', nil],
      [[cdx_row('https://sub.example.com/admin', '20240202030405', 'two'),
        cdx_row('https://example.com/api', '20240302030405', 'three')], nil, nil]
    ]
    payloads = []
    fetch = proc do |payload, *_args, **_kwargs|
      payloads << payload.dup
      pages.shift
    end

    Wayback::CDX.stub(:fetch_page, fetch) do
      Wayback::Query.stub(:sleep, nil) do
        result = Wayback::Query.fetch_cdx_history('https://example.com', 5.0)

        assert_equal 'complete', result[:status]
        assert_equal(%w[https://example.com/admin https://example.com/api],
                     result[:records].map { |row| row['url'] })
      end
    end

    assert_nil payloads.first['resumeKey']
    assert_equal 'next', payloads.last['resumeKey']
    refute_includes payloads.first, 'collapse'
  end

  def test_partial_rate_limit_retains_completed_pages
    pages = [
      [[cdx_row('https://example.com/admin', '20240102030405', 'one')], 'next', nil],
      [[], nil, 'rate_limited']
    ]

    Wayback::CDX.stub(:fetch_page, ->(*) { pages.shift }) do
      Wayback::Query.stub(:sleep, nil) do
        result = Wayback::Query.fetch_cdx_history('https://example.com', 5.0)

        assert_equal 'partial_rate_limited', result[:status]
        assert_equal ['rate_limited'], result[:reasons]
        assert_equal(['https://example.com/admin'], result[:records].map { |row| row['url'] })
      end
    end
  end

  def test_history_record_limit_retains_a_bounded_partial_result
    row = { 'url' => 'https://example.com/admin' }
    page = Array.new(Wayback::Query::MAX_CDX_RECORDS, row)

    Wayback::CDX.stub(:fetch_page, [page, 'next', nil]) do
      Wayback::Query.stub(:history_record, ->(record, *) { record }) do
        result = Wayback::Query.fetch_cdx_history('https://example.com', 5.0)

        assert_equal 'partial_limit', result[:status]
        assert_equal Wayback::Query::MAX_CDX_RECORDS, result[:records].length
        assert_equal ['record_limit'], result[:reasons]
      end
    end
  end

  def test_history_byte_limit_stops_before_retaining_record
    records = []
    page = [{ 'url' => 'https://example.com/admin' }]

    Wayback::Query.stub(:history_record, ->(record, *) { record }) do
      bytes, reason = Wayback::Query.append_history_page(
        records, Wayback::Query::MAX_CDX_RECORD_BYTES - 1, page, 'https://example.com'
      )

      assert_equal Wayback::Query::MAX_CDX_RECORD_BYTES - 1, bytes
      assert_equal 'byte_limit', reason
      assert_empty records
    end
  end

  def test_anchor_history_uses_three_bounded_urlkey_windows
    payloads = []
    fetch = proc do |payload, *_args, **_kwargs|
      payloads << payload
      [[cdx_row('https://example.com/admin', payload['from'], payload['from'])], nil, nil]
    end

    Wayback::CDX.stub(:fetch_page, fetch) do
      result = Wayback::Query.fetch_anchor_history(
        'https://example.com', 30.0, Wayback::Query.deadline_after(30.0), Time.utc(2026, 9, 27)
      )

      assert_equal 3, result[:records].length
      assert_equal(%w[three_months six_months one_year],
                   result[:records].map { |row| row['anchor_reason'] })
    end

    assert_equal ['urlkey'], payloads.map { |payload| payload['collapse'] }.uniq
    assert(payloads.all? { |payload| payload['from'] && payload['to'] })
  end

  def test_clean_not_found_does_not_call_availability_fallback
    history = { records: [], status: 'not_found', reasons: [], resume_key: nil }
    called = false

    Wayback::Query.stub(:fetch_cdx_history, history) do
      Wayback::Query.stub(:fetch_anchor_history, history) do
        Wayback::Query.stub(:availability_status, ->(*) { called = true }) do
          Wayback::Query.fetch_urls_with_status('https://example.com', 5.0)
        end
      end
    end

    refute called
  end

  def test_cdx_page_has_hard_timeout_when_transport_does_not_return
    Wayback::HTTP.stub(:get, ->(*) { sleep(0.1) }) do
      _rows, _resume_key, reason = Wayback::CDX.fetch_page(
        Wayback::CDX.build_payload('https://example.com', collapse: 'digest'), 0.01
      )

      assert_equal 'timeout', reason
    end
  end

  def test_fetch_urls_returns_history_selection_and_source_health
    history = {
      records: [Wayback::Query.history_record(
        cdx_row('https://example.com/admin', '20240102030405', 'one'), 'https://example.com'
      )],
      status: 'complete', reasons: [], resume_key: nil
    }
    Wayback::Query.stub(:fetch_cdx_history, history) do
      Wayback::Query.stub(:fetch_anchor_history, empty_history) do
        selection = { historical: [{ 'snapshot_url' => 'https://web.archive.org/web/a' }], changed: [] }
        Wayback::History.stub(:select, selection) do
          urls, status, _, records, availability, health, historical, changed =
            Wayback::Query.fetch_urls_with_status('https://example.com', 5.0)

          assert_equal ['https://example.com/admin'], urls
          assert_equal 'complete', status
          assert_equal 'not_requested', availability[:reason]
          assert_equal 'found', health.dig('cdx', 'status')
          assert_equal 1, records.length
          assert_equal 1, historical.length
          assert_empty changed
        end
      end
    end
  end

  def test_availability_fallback_preserves_cdx_failure_health
    availability = {
      state: :available,
      snapshots: { 'closest' => {
        'url' => 'https://web.archive.org/web/20240102030405/https://example.com/admin',
        'timestamp' => '20240102030405', 'status' => '200'
      } },
      reason: nil
    }
    history = { records: [], status: 'timeout', reasons: ['timeout'], resume_key: nil }

    Wayback::Query.stub(:fetch_cdx_history, history) do
      Wayback::Query.stub(:fetch_anchor_history, history) do
        Wayback::Query.stub(:availability_status, availability) do
          urls, status, _, _, _, health, historical, changed =
            Wayback::Query.fetch_urls_with_status('https://example.com', 5.0)

          assert_equal 'fallback', status
          assert_equal ['https://example.com/admin'], urls
          assert_equal 'timeout', health.dig('cdx', 'status')
          assert_equal 0, health.dig('cdx', 'records')
          assert_equal 'found', health.dig('availability', 'status')
          assert_empty historical
          assert_empty changed
        end
      end
    end
  end

  def test_availability_fallback_rejects_off_host_snapshot
    availability = {
      state: :available,
      snapshots: {
        'closest' => {
          'url' => 'https://web.archive.org/web/20240102030405/https://evil.test/admin',
          'timestamp' => '20240102030405', 'status' => '200'
        }
      },
      reason: nil
    }

    assert_empty Wayback::Query.availability_records(availability, 'https://example.com')
    health = Wayback::Query.availability_health(availability, [])

    assert_equal 'failed', health['status']
    assert_equal 'invalid_snapshot', health['reason']
  end

  def test_availability_rejects_oversized_body_without_materializing_it
    body = Object.new
    body.define_singleton_method(:bytesize) { Wayback::Query::MAX_AVAIL_BODY_BYTES + 1 }
    body.define_singleton_method(:to_s) { raise 'body should not be materialized' }
    response = FakeResponse.new(200, body, {})

    Wayback::HTTP.stub(:get, response) do
      result = Wayback::Query.check_availability_status('https://example.com', timeout_s: 1.0)

      assert_equal 'response_too_large', result[:reason]
    end
  end

  def test_duplicate_records_keep_first_compact_record
    records = [
      { 'url' => 'https://example.com/api', 'source' => 'wayback', 'timestamp' => '20240101' },
      { 'url' => 'https://example.com/api', 'source' => 'availability', 'timestamp' => '20240202' }
    ]

    _urls, compact = Wayback::Query.finalize_records(records)
    merged = compact.first

    assert_equal 'wayback', merged['source']
    assert_equal '20240101', merged['timestamp']
  end

  private

  def empty_history
    { records: [], status: 'not_found', reasons: [], resume_key: nil }
  end

  def cdx_row(url, timestamp, digest)
    { 'timestamp' => timestamp, 'original' => url, 'mimetype' => 'text/html', 'statuscode' => '200',
      'digest' => digest }
  end
end
