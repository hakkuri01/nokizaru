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
      source_health: {
        'cdx' => { 'status' => 'failed', 'records' => 0, 'reason' => 'service_unavailable' },
        'availability' => { 'status' => 'failed', 'records' => 0, 'reason' => 'service_unavailable' },
        'common_crawl' => { 'status' => 'skipped', 'records' => 0, 'reason' => 'deadline_exhausted', 'limit' => 50 },
        'virustotal' => { 'status' => 'skipped', 'records' => 0, 'reason' => 'missing_api_key' }
      },
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
    assert_equal 'failed', payload.dig('source_health', 'cdx', 'status')
    assert_equal payload['source_health'], JSON.parse(JSON.generate(payload['source_health']))
    refute_includes payload, 'truncation'
    assert_in_delta(1.2346, payload['elapsed_s'])
    assert_includes payload.dig('manual_pivots', 'calendar_url'), 'web.archive.org/web/*/'
  end

  def test_persist_adds_category_artifacts_and_counts
    ctx = Nokizaru::Context.new(run: {}, options: {})
    result = {
      availability: { state: :available }, archive_status: 'healthy', cdx_status: 'found', cdx_reasons: [],
      source_health: {}, urls: ['https://example.com/api/app.js?id=1'], url_records: [], manual_pivots: {}, elapsed_s: 1
    }

    Wayback.persist_wayback(ctx, result)

    assert_equal ['https://example.com/api/app.js?id=1'], ctx.run.dig('artifacts', 'wayback_javascript_urls')
    assert_equal ['https://example.com/api/app.js?id=1'], ctx.run.dig('artifacts', 'wayback_api_urls')
    assert_equal({ 'id' => 1 }, ctx.run.dig('modules', 'wayback', 'parameter_counts'))
  end

  def test_call_persists_complete_failure_schema_and_reraises_timeout
    ctx = Nokizaru::Context.new(run: {}, options: {})

    Wayback.stub(:execute_query, ->(*) { raise Timeout::Error, 'deadline exceeded' }) do
      assert_raises(Timeout::Error) { Wayback.call('https://example.com', ctx, timeout_s: 12) }
    end

    payload = ctx.run.dig('modules', 'wayback')

    assert_equal 2, payload['schema_version']
    assert_equal 'failed', payload['status']
    assert payload['timed_out']
    assert_empty payload['urls']
    assert_equal [], payload['review_urls']
    assert_equal 'timeout', payload.dig('source_health', 'cdx', 'reason')
  end

  def test_presenter_exposes_source_status_and_reason
    rows = []
    row = proc { |_type, label, value, **| rows << [label, value] }
    health = {
      'common_crawl' => { 'status' => 'failed', 'reason' => 'http_403' },
      'virustotal' => { 'status' => 'skipped', 'reason' => 'missing_api_key' }
    }

    Nokizaru::UI.stub(:row, row) { Wayback::Presenter.source_health(health) }

    assert_includes rows, ['Common Crawl source', 'Failed (HTTP 403)']
    assert_includes rows, ['VirusTotal source', 'Skipped (Missing API key)']
  end

  def test_presenter_exposes_cdx_restriction_with_fallback_records
    rows = []
    row = proc { |_type, label, value, **| rows << [label, value] }

    Nokizaru::UI.stub(:row, row) do
      Wayback::Presenter.cdx_status(
        'archive_degraded', ['https://example.com/login'], { 'status' => 'failed', 'reason' => 'http_403' }
      )
    end

    assert_includes rows, ['Fetching URLs from CDX', '1 fallback (HTTP 403)']
  end

  def test_presenter_labels_known_availability_timeout
    rows = []
    row = proc { |_type, label, value, **| rows << [label, value] }

    Nokizaru::UI.stub(:row, row) do
      Wayback::Presenter.availability_status(:unknown, { 'status' => 'timeout', 'reason' => 'timeout' })
    end

    assert_includes rows, ['Checking availability on Wayback Machine', 'Timeout']
  end

  def test_presenter_humanizes_source_reasons
    assert_equal 'Request failed', Wayback::Presenter.human_status('request_failed')
    assert_equal 'Missing API key', Wayback::Presenter.human_status('missing_api_key')
    assert_equal 'Deadline exhausted', Wayback::Presenter.human_status('deadline_exhausted')
    assert_equal 'Service unavailable', Wayback::Presenter.human_status('service_unavailable')
  end

  def test_workflow_keeps_wayback_inside_outer_guard
    workflow = Class.new { include Nokizaru::CLI::Runner::Workflow }.new

    assert_in_delta 60.0, workflow.send(:module_timeout_s, { timeout: 30.0 }, :wayback)
    assert_in_delta 24.0, workflow.send(:wayback_timeout_cap)
    assert_in_delta 10.0, Wayback::TOTAL_TIMEOUT
    assert_equal 2, Wayback::RETRIES
  end

  def test_availability_reserves_half_the_module_budget_for_cdx
    availability = { state: :not_available, snapshots: nil, reason: nil }
    health = {
      'availability' => Wayback::Query.source_health('empty'),
      'cdx' => Wayback::Query.source_health('empty'),
      'common_crawl' => Wayback::Query.source_health('skipped', reason: 'deadline_exhausted'),
      'virustotal' => Wayback::Query.source_health('skipped', reason: 'missing_api_key')
    }
    observed_budget = nil
    fetch = proc do |_target, timeout_s, _snapshots, **_kwargs|
      observed_budget = timeout_s
      [[], 'not_found', [], [], availability, health]
    end

    Wayback::Query.stub(:availability_status, availability) do
      Wayback::Query.stub(:fetch_urls_with_status, fetch) do
        Wayback.execute_query('https://example.com', 24.0)
      end
    end

    assert_in_delta 12.0, observed_budget
  end
end
