# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryEdgeTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback

  def test_expired_deadline_never_restores_requested_timeout
    Process.stub(:clock_gettime, 10.0) do
      assert_in_delta 0.0, Wayback::Query.remaining_time(9.0)
      assert_in_delta 0.0, Wayback::Query.bounded_timeout(5.0, deadline_at: 9.0)
    end
  end

  def test_source_health_is_json_safe
    health = Wayback::Query.source_health('failed', reason: 'http_403')

    assert_equal health, JSON.parse(JSON.generate(health))
  end

  def test_response_classification
    assert_equal 'rate_limited', Wayback::Query.response_reason(429)
    assert_equal 'service_unavailable', Wayback::Query.response_reason(503)
    assert_equal 'http_403', Wayback::Query.response_reason(403)
  end

  def test_history_payload_rejects_missing_hostname
    assert_raises(ArgumentError) { Wayback::CDX.build_payload('not a url', collapse: 'digest') }
  end

  def test_history_record_rejects_subdomains_userinfo_and_malformed_urls
    target = 'https://example.com'

    assert_nil Wayback::Query.history_record(cdx_row('https://sub.example.com/admin'), target)
    assert_nil Wayback::Query.history_record(cdx_row('https://user@example.com/admin'), target)
    assert_nil Wayback::Query.history_record(cdx_row('https://@example.com/admin'), target)
    assert_nil Wayback::Query.history_record(cdx_row('not a url'), target)
    assert_equal 'https://example.com/admin', Wayback::Query.history_record(
      cdx_row('https://example.com/admin'), target
    )['url']
  end

  def test_archive_status_marks_partial_retrieval_degraded
    health = {
      'availability' => Wayback::Query.source_health('skipped', reason: 'not_requested'),
      'cdx' => Wayback::Query.source_health('rate_limited', reason: 'rate_limited')
    }

    assert_equal 'degraded', Wayback::Query.archive_status({}, 'partial_rate_limited', ['rate_limited'], health)
  end

  def test_health_reason_matches_partial_status_priority
    reasons = %w[timeout record_limit]

    assert_equal 'timeout', Wayback::Query.health_reason('partial_timeout', reasons)
  end

  private

  def cdx_row(url)
    { 'timestamp' => '20240102030405', 'original' => url, 'mimetype' => 'text/html', 'statuscode' => '200',
      'digest' => 'digest' }
  end
end
