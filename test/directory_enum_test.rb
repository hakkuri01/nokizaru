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

    result = DirectoryEnum.__send__(:dir_result, scan, runtime, stats, stop_meta, 1.0, 1.0)

    assert_equal ['https://example.com/noise', 'https://example.com/admin'], result['found']
    assert_equal ['https://example.com/admin'], result['prioritized_found']
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

  def test_store_dir_result_falls_back_to_found_paths
    ctx = artifact_context
    result = directory_result_for_artifacts(prioritized: [])

    DirectoryEnum.__send__(:store_dir_result, { options: { ctx: ctx } }, result)

    assert_equal ['https://example.com/noise'], ctx.artifacts['paths']
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
