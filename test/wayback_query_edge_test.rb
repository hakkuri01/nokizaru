# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryEdgeTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback

  def test_availability_variants_handles_invalid_target_as_literal
    assert_equal ['not a url'], Wayback::Query.availability_variants('not a url')
  end

  def test_expired_deadline_never_restores_requested_timeout
    Process.stub(:clock_gettime, 10.0) do
      assert_in_delta 0.0, Wayback::Query.remaining_time(9.0)
      assert_in_delta 0.0, Wayback::Query.bounded_timeout(5.0, deadline_at: 9.0)
    end
  end

  def test_unexpired_deadline_bounds_timeout
    Process.stub(:clock_gettime, 10.0) do
      assert_in_delta 2.0, Wayback::Query.bounded_timeout(5.0, deadline_at: 12.0)
      assert_in_delta 2.5, Wayback::Query.remaining_time(nil, 2.5)
    end
  end

  def test_source_health_is_json_safe
    health = Wayback::Query.source_health('failed', reason: 'http_403', limit: 50)

    assert_equal health, JSON.parse(JSON.generate(health))
  end

  def test_response_and_empty_status_classification
    assert_equal 'rate_limited', Wayback::Query.response_reason(429)
    assert_equal 'service_unavailable', Wayback::Query.response_reason(503)
    assert_equal 'http_403', Wayback::Query.response_reason(403)
    assert_equal 'archive_degraded', Wayback::Query.cdx_empty_status(['service_unavailable'], false)
    assert_equal 'timeout', Wayback::Query.cdx_empty_status([], true)
    assert_equal 'not_found', Wayback::Query.cdx_empty_status([], false)
  end

  def test_normalize_cdx_status_corrects_empty_and_found_mismatches
    assert_equal 'found', Wayback::Query.normalize_cdx_status(['https://example.com/a'], 'not_found')
    assert_equal 'not_found', Wayback::Query.normalize_cdx_status([], 'found')
    assert_equal 'timeout', Wayback::Query.normalize_cdx_status([], 'timeout_with_fallback')
  end

  def test_optional_source_failure_does_not_degrade_archive_org_health
    health = {
      'availability' => Wayback::Query.source_health('empty'),
      'cdx' => Wayback::Query.source_health('empty'),
      'common_crawl' => Wayback::Query.source_health('failed', reason: 'request_failed')
    }

    assert_equal 'healthy', Wayback::Query.archive_status({ state: :not_available }, 'not_found', [], health)
  end

  def test_append_unique_urls_preserves_first_seen_order
    aggregate = ['https://example.com/a']
    seen = { 'https://example.com/a' => true }

    Wayback::Query.append_unique_urls(aggregate, seen, %w[https://example.com/a https://example.com/b])

    assert_equal %w[https://example.com/a https://example.com/b], aggregate
  end
end
