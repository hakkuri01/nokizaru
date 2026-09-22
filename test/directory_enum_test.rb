# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_directory_probe_uses_get_for_full_and_seeded_modes
    assert_equal :get, DirectoryEnum.__send__(:request_method_for_mode, DirectoryEnum.const_get(:MODE_FULL, false))
    assert_equal :get, DirectoryEnum.__send__(:request_method_for_mode, DirectoryEnum.const_get(:MODE_SEEDED, false))
    assert_equal :head, DirectoryEnum.__send__(:request_method_for_mode, DirectoryEnum.const_get(:MODE_HOSTILE, false))
  end

  def test_dir_result_exports_only_distinct_directory_fields
    scan = {
      normalized_target: 'https://example.com',
      scan_target: 'https://example.com',
      anchor: { reanchor: false, reason: '' },
      options: { target: 'https://example.com' }
    }
    runtime = {
      signal_responses: [],
      all_found: ['https://example.com/noise', 'https://example.com/admin'],
      found: ['https://example.com/admin'],
      low_confidence_found: ['https://example.com/noise'],
      stdout_found: ['https://example.com/admin'],
      confirmed_found: ['https://example.com/admin'],
      responses: []
    }
    stats = DirectoryEnum.__send__(:init_stats)
    stop_meta = { mode: 'full', reason: '', preflight: {}, budgets: {} }

    result = DirectoryEnum.__send__(:dir_result, scan, runtime, stats, stop_meta, { elapsed: 1.0, rps: 1.0 })

    assert_equal ['https://example.com/noise', 'https://example.com/admin'], result['found']
    assert_equal ['https://example.com/admin'], result['prioritized_found']
    assert_equal ['https://example.com/admin'], result['stdout_found']
    assert_equal ['https://example.com/noise'], result['low_confidence_found']
    assert_equal %w[
      target found prioritized_found stdout_found confirmed_found low_confidence_found high_signal_found by_status stats
    ], result.keys
    refute result.key?('raw_found')
    refute result.key?('actionable_found')
  end

  def test_store_dir_result_prefers_prioritized_paths
    ctx = artifact_context
    result = directory_result_for_artifacts(prioritized: ['https://example.com/admin'])

    DirectoryEnum.__send__(:store_dir_result, { options: { ctx: ctx } }, result)

    assert_equal ['https://example.com/admin'], ctx.artifacts['paths']
    assert_equal ['https://example.com/admin'], ctx.artifacts['prioritized_paths']
  end

  def test_store_dir_result_never_falls_back_to_raw_found_paths
    ctx = artifact_context
    result = directory_result_for_artifacts(prioritized: [])

    DirectoryEnum.__send__(:store_dir_result, { options: { ctx: ctx } }, result)

    assert_empty ctx.artifacts['paths']
    refute ctx.artifacts.key?('prioritized_paths')
  end

  def test_hostile_mode_stops_after_sustained_transport_failures_without_signal
    stop_state = {
      stop: false,
      mode: DirectoryEnum.const_get(:MODE_HOSTILE, false),
      reason: nil,
      budgets: DirectoryEnum.const_get(:MODE_BUDGETS, false).fetch(DirectoryEnum.const_get(:MODE_HOSTILE, false))
    }
    timeout_state = { current: 2.0 }
    runtime = {
      adaptation_state: { pressure_streak: 0, low_yield_streak: 0 },
      stats: { success: 1, errors: 300 }
    }

    result = DirectoryEnum.__send__(
      :apply_mode_downgrade!, 330, runtime[:stats], stop_state, timeout_state, runtime: runtime
    )

    assert_equal :stopped, result
    assert stop_state[:stop]
    assert_match(/sustained hostile transport failures/, stop_state[:reason])
  end

  def test_hostile_mode_keeps_scanning_when_transport_failures_have_signal
    stop_state = {
      stop: false,
      mode: DirectoryEnum.const_get(:MODE_HOSTILE, false),
      reason: nil,
      budgets: DirectoryEnum.const_get(:MODE_BUDGETS, false).fetch(DirectoryEnum.const_get(:MODE_HOSTILE, false))
    }
    timeout_state = { current: 2.0 }
    runtime = {
      adaptation_state: { pressure_streak: 0, low_yield_streak: 0 },
      stats: { success: 8, errors: 300 }
    }

    result = DirectoryEnum.__send__(
      :apply_mode_downgrade!, 330, runtime[:stats], stop_state, timeout_state, runtime: runtime
    )

    assert_nil result
    refute stop_state[:stop]
  end

  def test_module_seed_paths_are_relative_to_path_based_targets
    ctx = Struct.new(:run).new(
      {
        'artifacts' => {},
        'modules' => {
          'crawler' => {
            'internal_links' => ['https://example.com/app/deep/reports']
          }
        }
      }
    )

    plan = DirectoryEnum.__send__(
      :build_scan_plan,
      target: 'https://example.com/app',
      words: ['admin'],
      filext: '',
      ctx: ctx
    )

    assert_includes plan[:seed_urls], 'https://example.com/app/deep/reports'
    refute_includes plan[:seed_urls], 'https://example.com/app/app/deep/reports'
    assert_equal ['/deep/reports'], plan[:crawler_paths]
  end

  def test_request_aware_fingerprints_remove_reflected_url_shapes
    cases = [
      ['Missing https://example.com/one', 'https://example.com/one',
       'Missing https://example.com/two', 'https://example.com/two'],
      ['Missing /one%20path', 'https://example.com/one%20path',
       'Missing /two%20path', 'https://example.com/two%20path'],
      ['Missing https%3A%2F%2Fexample.com%2Fone', 'https://example.com/one',
       'Missing https%3A%2F%2Fexample.com%2Ftwo', 'https://example.com/two'],
      ['Missing https://example.com/a?x=1&amp;y=2', 'https://example.com/a?x=1&y=2',
       'Missing https://example.com/b?x=1&amp;y=2', 'https://example.com/b?x=1&y=2'],
      ['Missing segment one', 'https://example.com/one',
       'Missing segment two', 'https://example.com/two'],
      ['Missing token alpha', 'https://example.com/missing?token=alpha',
       'Missing token beta', 'https://example.com/missing?token=beta']
    ]

    cases.each do |body_a, url_a, body_b, url_b|
      assert_equal DirectoryEnum.__send__(:body_fingerprint, body_a, request_url: url_a),
                   DirectoryEnum.__send__(:body_fingerprint, body_b, request_url: url_b)
    end
  end

  def test_reflected_redirect_transforms_share_a_generic_cluster
    first = DirectoryEnum.__send__(
      :redirect_pattern, 'https://example.com/alpha', 'https://example.com/missing/alpha'
    )
    second = DirectoryEnum.__send__(
      :redirect_pattern, 'https://example.com/beta', 'https://example.com/missing/beta'
    )

    assert_equal first, second
    assert first.start_with?('reflected_path:')
    assert DirectoryEnum.__send__(:generic_redirect_pattern?, first)
  end

  def test_redirect_to_child_path_is_not_treated_as_reflected_template
    pattern = DirectoryEnum.__send__(
      :redirect_pattern, 'https://example.com/account', 'https://example.com/account/setup'
    )

    assert_equal 'path_specific:https:example.com:/account/setup', pattern
    refute DirectoryEnum.__send__(:generic_redirect_pattern?, pattern)
  end

  def test_path_based_targets_evaluate_high_signal_paths_relatively
    sample = { content_type: 'text/html', body_length: 100, title: 'admin' }

    decision = DirectoryEnum.__send__(
      :finding_confidence, 'https://example.com/app/admin', 200, sample, nil, 'https://example.com/app'
    )

    assert_equal :confirmed, decision[:level]
    assert_equal 'high_signal_content', decision[:reason]
    assert_operator DirectoryEnum.__send__(
      :score_path_signal, 'https://example.com/app/admin', 200, 'https://example.com/app'
    ), :>, 0
  end

  def test_final_reconciliation_demotes_early_promotions_without_losing_raw_evidence
    sample = { status: 200, content_type: 'text/html', body_length: 100, tolerance: 128,
               title: 'missing', fingerprint: 'same' }
    scan = result_scan
    runtime = result_runtime(
      observations: [{ url: 'https://example.com/admin', status: 200, sample: sample }],
      baseline: sample,
      responses: [['https://example.com/admin', 200]]
    )
    result = DirectoryEnum.__send__(:dir_result, scan, runtime, DirectoryEnum.__send__(:init_stats),
                                    result_stop_meta, { elapsed: 1.0, rps: 1.0 })

    assert_equal ['https://example.com/admin'], result['found']
    assert_equal({ '200' => ['https://example.com/admin'] }, result['by_status'])
    assert_empty result['prioritized_found']
    assert_equal ['https://example.com/admin'], result['low_confidence_found']
    assert_empty result['high_signal_found']
  end

  def test_homogeneous_guesses_preserve_crawler_and_status_divergent_findings
    sample = { status: 403, content_type: 'text/plain', body_length: 100, title: nil, fingerprint: 'uniform' }
    observations = Array.new(39) do |index|
      { url: "https://example.com/guess#{index}", status: 403, sample: sample }
    end
    observations << { url: 'https://example.com/known', status: 403, sample: sample }
    observations << { url: 'https://example.com/different', status: 401, sample: sample.merge(status: 401) }
    scan = result_scan(crawler_paths: ['/known/'])
    runtime = result_runtime(observations: observations, baseline: nil, responses: [])

    reconciled = DirectoryEnum.__send__(:reconcile_candidate_findings, scan, runtime)

    assert_includes reconciled[:prioritized], 'https://example.com/known'
    assert_includes reconciled[:prioritized], 'https://example.com/different'
    assert_includes reconciled[:low], 'https://example.com/guess0'
  end

  def test_crawler_corroboration_preserves_case_sensitive_paths
    scan = result_scan(crawler_paths: ['/AdminPanel', '/encoded%2fpath'])
    paths = DirectoryEnum.__send__(:normalized_crawler_paths, scan)

    assert DirectoryEnum.__send__(:crawler_corroborated?, scan, 'https://example.com/AdminPanel', paths)
    refute DirectoryEnum.__send__(:crawler_corroborated?, scan, 'https://example.com/adminpanel', paths)
    assert DirectoryEnum.__send__(:crawler_corroborated?, scan, 'https://example.com/encoded%2Fpath', paths)
  end

  def test_homogeneous_demotion_preserves_structurally_distinct_pages
    observations = Array.new(40) do |index|
      {
        url: "https://example.com/page#{index}", status: 200,
        sample: { status: 200, content_type: 'text/html', body_length: 100,
                  title: "Page #{index}", fingerprint: "unique#{index}" }
      }
    end
    runtime = result_runtime(observations: observations, baseline: nil, responses: [])

    reconciled = DirectoryEnum.__send__(:reconcile_candidate_findings, result_scan, runtime)

    assert_equal 40, reconciled[:prioritized].length
  end

  def test_homogeneous_demotion_preserves_distinct_titleless_pages
    observations = Array.new(40) do |index|
      {
        url: "https://example.com/api/page#{index}", status: 200,
        sample: { status: 200, content_type: 'application/json', body_length: 100 + index,
                  title: nil, fingerprint: "json#{index}" }
      }
    end
    runtime = result_runtime(observations: observations, baseline: nil, responses: [])

    reconciled = DirectoryEnum.__send__(:reconcile_candidate_findings, result_scan, runtime)

    assert_equal 40, reconciled[:prioritized].length
  end

  def test_high_signal_cap_is_applied_after_reconciled_filtering
    prioritized = 'https://example.com/admin/this-is-the-reconciled-result'
    responses = Array.new(201) { |index| ["https://example.com/admin/n#{index}", 200] }
    responses << [prioritized, 200]

    ranked = DirectoryEnum.__send__(:rank_high_signal_paths, responses, 'https://example.com', Set[prioritized])

    assert_equal [prioritized], ranked
  end

  def test_final_reconciliation_replaces_runtime_confidence_buckets
    runtime = {
      found: ['https://example.com/early'], confirmed_found: ['https://example.com/early'],
      low_confidence_found: []
    }
    reconciled = {
      prioritized: ['https://example.com/final'], confirmed: [], low: ['https://example.com/early']
    }

    DirectoryEnum.__send__(:apply_reconciled_runtime_buckets!, runtime, reconciled)

    assert_equal ['https://example.com/final'], runtime[:found]
    assert_equal ['https://example.com/final'], runtime[:stdout_found]
    assert_empty runtime[:confirmed_found]
    assert_equal ['https://example.com/early'], runtime[:low_confidence_found]
  end

  def test_runtime_reconciliation_updates_adaptation_buckets_at_window_boundary
    sample = { status: 403, content_type: 'text/plain', body_length: 100, title: nil, fingerprint: 'uniform' }
    observations = Array.new(40) do |index|
      { url: "https://example.com/guess#{index}", status: 403, sample: sample }
    end
    runtime = result_runtime(observations: observations, baseline: nil, responses: [])
    runtime.merge!(count: DirectoryEnum.const_get(:PRESSURE_WINDOW_REQUESTS),
                   found: observations.map { |item| item[:url] }, stdout_found: observations.map { |item| item[:url] })

    DirectoryEnum.__send__(:reconcile_runtime_for_adaptation!, result_scan, runtime)

    assert_empty runtime[:found]
    assert_empty runtime[:stdout_found]
    assert_equal 40, runtime[:low_confidence_found].length
  end

  def test_candidate_observation_uses_synchronized_metadata
    runtime = {
      candidate_observations: [], stats: DirectoryEnum.__send__(:init_stats),
      found: [], confirmed_found: [], low_confidence_found: [], count: 99
    }
    observed_at = Time.at(123)

    input = { status: 200, sample: {}, observed_count: 7, observed_at: observed_at }
    DirectoryEnum.__send__(:track_confidence_finding, result_scan, runtime, 'https://example.com/noise',
                           { level: :low, reason: 'test' }, input)

    observation = runtime[:candidate_observations].first

    assert_equal 7, observation[:observed_count]
    assert_equal observed_at, observation[:observed_at]
  end

  def test_first_actionable_uses_observation_order_not_completion_order
    runtime = {}
    entries = [
      { observed_count: 9, observed_at: Time.at(9), decision: { level: :likely } },
      { observed_count: 2, observed_at: Time.at(2), decision: { level: :confirmed } }
    ]

    DirectoryEnum.__send__(:apply_reconciled_first_actionable!, runtime, entries)

    assert_equal 2, runtime[:first_actionable_count]
    assert_equal Time.at(2), runtime[:first_actionable_at]
  end

  def test_title_presence_distinguishes_candidate_from_titleless_baseline
    sample = { body_length: 100, title: 'Administration' }
    baseline = { body_length: 100, tolerance: 20, title: nil }

    refute DirectoryEnum.send(:title_and_length_match?, sample, baseline)
    assert DirectoryEnum.send(:title_and_length_match?, sample.merge(title: nil), baseline)
  end

  def test_extension_phase_requires_base_path_signal_or_observed_usefulness
    runtime = extension_runtime(count: 120, found: [], all_found: [], low_confidence_found: [])

    DirectoryEnum.__send__(:update_extension_state!, runtime)

    refute runtime[:extension_state][:enabled]

    runtime = extension_runtime(
      count: 120,
      found: ['https://example.com/admin'],
      all_found: [],
      low_confidence_found: []
    )

    DirectoryEnum.__send__(:update_extension_state!, runtime)

    assert runtime[:extension_state][:enabled]
    assert_equal 'actionable base-path signal', runtime[:extension_state][:reason]
  end

  def test_dynamic_concurrency_throttles_bad_windows_and_recovers_on_healthy_signal
    runtime = concurrency_runtime(current: 8, max: 8)
    runtime[:adaptation_state][:last_window] = { error_ratio: 0.5, transport_ratio: 0.3 }

    DirectoryEnum.__send__(:update_dynamic_concurrency!, runtime)

    assert_equal 4, runtime[:concurrency_state][:current]

    runtime[:count] = 340
    runtime[:found] = ['https://example.com/admin']
    runtime[:adaptation_state][:last_window] = { error_ratio: 0.0, transport_ratio: 0.0 }

    DirectoryEnum.__send__(:update_dynamic_concurrency!, runtime)

    assert_equal 5, runtime[:concurrency_state][:current]
  end

  private

  def result_scan(crawler_paths: [])
    {
      normalized_target: 'https://example.com', scan_target: 'https://example.com',
      anchor: { reanchor: false, reason: '' }, options: { target: 'https://example.com' },
      url_plan: { crawler_paths: crawler_paths }
    }
  end

  def result_runtime(observations:, baseline:, responses:)
    {
      candidate_observations: observations, soft_404_baseline: baseline,
      confidence_context: { snapshot: neutral_confidence_context },
      stats: { success: observations.length },
      signal_responses: responses, all_found: observations.map { |item| item[:url] }, responses: responses,
      found: [], confirmed_found: [], low_confidence_found: [], stdout_found: []
    }
  end

  def neutral_confidence_context
    {
      waf_likelihood_score: 0.0, redirect_cluster_dominance_ratio: 0.0, soft_404_dominance_ratio: 0.0,
      sensitive_status_total: 0, sensitive_status_homogeneity_ratio: 0.0,
      sensitive_status_fingerprint_uniqueness_ratio: 0.0, context_sources_used: [], context_sources_missing: []
    }
  end

  def result_stop_meta
    { mode: 'full', reason: '', preflight: {}, budgets: {} }
  end

  def artifact_context
    Struct.new(:run, :artifacts) do
      def add_artifact(key, values)
        artifacts[key] = values
      end
    end.new({ 'modules' => {} }, {})
  end

  def directory_result_for_artifacts(prioritized:)
    {
      'found' => ['https://example.com/noise'],
      'prioritized_found' => prioritized,
      'high_signal_found' => []
    }
  end

  def extension_runtime(count:, found:, all_found:, low_confidence_found:)
    {
      count: count,
      found: found,
      all_found: all_found,
      low_confidence_found: low_confidence_found,
      extension_state: { enabled: false, reason: nil },
      target_shape: {},
      confidence_context: {
        snapshot: {
          soft_404_dominance_ratio: 0.0,
          redirect_cluster_dominance_ratio: 0.0
        }
      }
    }
  end

  def concurrency_runtime(current:, max:)
    {
      count: 180,
      found: [],
      all_found: [],
      concurrency_state: { current: current, max: max, min: 2, last_eval_count: 0 },
      adaptation_state: { last_window: {} }
    }
  end
end
