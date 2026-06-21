# frozen_string_literal: true

require_relative 'test_helper'

class WaybackQueryEdgeTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback

  def test_availability_variants_handles_invalid_target_as_literal
    assert_equal ['not a url'], Wayback::Query.availability_variants('not a url')
  end

  def test_timeout_helpers_bound_deadline_and_fallback_values
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0

    assert_operator Wayback::Query.remaining_time(deadline), :>, 0.0
    assert_equal 2.5, Wayback::Query.remaining_time(nil, 2.5)
    assert_operator Wayback::Query.bounded_timeout(10.0, deadline_at: deadline), :<=, 5.0
  end

  def test_archive_status_marks_found_and_unknown_states
    assert_equal 'healthy', Wayback::Query.archive_status({ state: :unknown }, 'found_reduced', [])
    assert_equal 'unknown', Wayback::Query.archive_status({ state: :unknown }, 'not_found', [])
  end

  def test_response_reason_and_empty_status_classification
    assert_equal 'rate_limited', Wayback::Query.response_reason(429)
    assert_equal 'service_unavailable', Wayback::Query.response_reason(503)
    assert_equal 'http_404', Wayback::Query.response_reason(404)
    assert_equal 'archive_degraded', Wayback::Query.cdx_empty_status(['service_unavailable'], false)
    assert_equal 'timeout', Wayback::Query.cdx_empty_status([], true)
    assert_equal 'not_found', Wayback::Query.cdx_empty_status([], false)
  end

  def test_normalize_cdx_status_corrects_empty_and_found_mismatches
    assert_equal 'found', Wayback::Query.normalize_cdx_status(['https://example.com/a'], 'not_found')
    assert_equal 'not_found', Wayback::Query.normalize_cdx_status([], 'found')
    assert_equal 'timeout', Wayback::Query.normalize_cdx_status([], 'timeout_with_fallback')
  end

  def test_append_unique_urls_preserves_first_seen_order
    aggregate = ['https://example.com/a']
    seen = { 'https://example.com/a' => true }
    urls = [
      'https://example.com/a',
      'https://example.com/b',
      'https://example.com/c'
    ]

    Wayback::Query.append_unique_urls(aggregate, seen, urls)

    assert_equal ['https://example.com/a', 'https://example.com/b', 'https://example.com/c'], aggregate
  end
end
