# frozen_string_literal: true

require_relative 'test_helper'

class WaybackModuleTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback

  def test_persist_wayback_exports_archive_status_and_manual_pivots
    ctx = Nokizaru::Context.new(run: { 'modules' => {}, 'artifacts' => {}, 'findings' => [] }, options: {})
    result = {
      availability: { state: :unknown, reason: 'service_unavailable', variant: 'https://example.com' },
      archive_status: 'degraded',
      cdx_status: 'archive_degraded',
      cdx_reasons: ['service_unavailable'],
      urls: [],
      manual_pivots: Wayback::Query.manual_pivots('https://example.com'),
      elapsed_s: 1.23456
    }

    Wayback.persist_wayback(ctx, result)

    payload = ctx.run.dig('modules', 'wayback')
    assert_equal 'unknown', payload['availability']
    assert_equal 'service_unavailable', payload['availability_reason']
    assert_equal 'degraded', payload['archive_status']
    assert_equal 'archive_degraded', payload['cdx_status']
    assert_equal ['service_unavailable'], payload['cdx_reasons']
    assert_equal 1.2346, payload['elapsed_s']
    assert_includes payload.dig('manual_pivots', 'calendar_url'), 'web.archive.org/web/*/'
  end
end
