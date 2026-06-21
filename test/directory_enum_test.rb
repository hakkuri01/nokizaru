# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_directory_probe_uses_get_for_full_and_seeded_modes
    assert_equal :get, DirectoryEnum.request_method_for_mode(DirectoryEnum::MODE_FULL)
    assert_equal :get, DirectoryEnum.request_method_for_mode(DirectoryEnum::MODE_SEEDED)
    assert_equal :head, DirectoryEnum.request_method_for_mode(DirectoryEnum::MODE_HOSTILE)
  end

  def test_dir_result_keeps_actionable_findings_separate_from_raw_candidates
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
    stats = DirectoryEnum.init_stats
    stop_meta = { mode: 'full', reason: '', preflight: {}, budgets: {} }

    result = DirectoryEnum.dir_result(scan, runtime, stats, stop_meta, 1.0, 1.0)

    assert_equal ['https://example.com/noise', 'https://example.com/admin'], result['found']
    assert_equal ['https://example.com/noise', 'https://example.com/admin'], result['raw_found']
    assert_equal ['https://example.com/admin'], result['actionable_found']
    assert_equal ['https://example.com/noise'], result['low_confidence_found']
  end

  def test_hostile_mode_stops_after_sustained_transport_failures_without_signal
    stop_state = {
      stop: false,
      mode: DirectoryEnum::MODE_HOSTILE,
      reason: nil,
      budgets: DirectoryEnum::MODE_BUDGETS.fetch(DirectoryEnum::MODE_HOSTILE)
    }
    timeout_state = { current: 2.0 }
    runtime = {
      adaptation_state: { pressure_streak: 0, low_yield_streak: 0 },
      stats: { success: 1, errors: 300 }
    }

    result = DirectoryEnum.apply_mode_downgrade!(330, runtime[:stats], stop_state, timeout_state, runtime: runtime)

    assert_equal :stopped, result
    assert stop_state[:stop]
    assert_match(/sustained hostile transport failures/, stop_state[:reason])
  end

  def test_hostile_mode_keeps_scanning_when_transport_failures_have_signal
    stop_state = {
      stop: false,
      mode: DirectoryEnum::MODE_HOSTILE,
      reason: nil,
      budgets: DirectoryEnum::MODE_BUDGETS.fetch(DirectoryEnum::MODE_HOSTILE)
    }
    timeout_state = { current: 2.0 }
    runtime = {
      adaptation_state: { pressure_streak: 0, low_yield_streak: 0 },
      stats: { success: 8, errors: 300 }
    }

    result = DirectoryEnum.apply_mode_downgrade!(330, runtime[:stats], stop_state, timeout_state, runtime: runtime)

    assert_nil result
    refute stop_state[:stop]
  end

  def test_scan_plan_prioritizes_module_artifact_seeds_and_estimates_lazy_total
    ctx = Struct.new(:run).new(
      {
        'artifacts' => {
          'wayback_urls' => ['https://example.com/admin/reports'],
          'paths' => ['/api/private']
        },
        'modules' => {}
      }
    )

    plan = DirectoryEnum.build_scan_plan(
      target: 'https://example.com',
      words: %w[login api admin],
      filext: 'php,html',
      ctx: ctx
    )

    assert_includes plan[:seed_urls], 'https://example.com/admin/reports'
    assert_includes plan[:seed_urls], 'https://example.com/api/private'
    assert_equal 3 + plan[:seed_urls].length + 6, plan[:estimated_total]
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

    plan = DirectoryEnum.build_scan_plan(
      target: 'https://example.com/app',
      words: ['admin'],
      filext: '',
      ctx: ctx
    )

    assert_includes plan[:seed_urls], 'https://example.com/app/deep/reports'
    refute_includes plan[:seed_urls], 'https://example.com/app/app/deep/reports'
  end

  def test_lazy_queue_generates_base_paths_before_signal_gated_extensions
    scan = lazy_scan(words: %w[admin login], filext: 'php')
    runtime = {
      extension_state: { enabled: false },
      count: 0,
      all_found: [],
      found: [],
      low_confidence_found: []
    }
    queue = DirectoryEnum.build_work_queue(scan, runtime)

    assert_equal 'https://example.com/robots.txt', queue.pop(true)
    assert_equal 'https://example.com/admin', queue.pop(true)
    assert_equal 'https://example.com/login', queue.pop(true)
    assert_raises(ThreadError) { queue.pop(true) }

    runtime[:extension_state][:enabled] = true
    queue = DirectoryEnum.build_work_queue(scan, runtime)
    3.times { queue.pop(true) }

    assert_equal 'https://example.com/admin.php', queue.pop(true)
    assert_equal 'https://example.com/login.php', queue.pop(true)
  end

  def test_extension_phase_requires_base_path_signal_or_cached_usefulness
    runtime = extension_runtime(count: 120, found: [], all_found: [], low_confidence_found: [])

    DirectoryEnum.update_extension_state!(runtime)

    refute runtime[:extension_state][:enabled]

    runtime = extension_runtime(
      count: 120,
      found: ['https://example.com/admin'],
      all_found: [],
      low_confidence_found: []
    )

    DirectoryEnum.update_extension_state!(runtime)

    assert runtime[:extension_state][:enabled]
    assert_equal 'actionable base-path signal', runtime[:extension_state][:reason]
  end

  def test_dynamic_concurrency_throttles_bad_windows_and_recovers_on_healthy_signal
    runtime = concurrency_runtime(current: 8, max: 8)
    runtime[:adaptation_state][:last_window] = { error_ratio: 0.5, transport_ratio: 0.3 }

    DirectoryEnum.update_dynamic_concurrency!(runtime)

    assert_equal 4, runtime[:concurrency_state][:current]

    runtime[:count] = 340
    runtime[:found] = ['https://example.com/admin']
    runtime[:adaptation_state][:last_window] = { error_ratio: 0.0, transport_ratio: 0.0 }

    DirectoryEnum.update_dynamic_concurrency!(runtime)

    assert_equal 5, runtime[:concurrency_state][:current]
  end

  def test_marginal_value_stop_triggers_on_dominant_low_information_shape
    runtime = {
      count: 400,
      stop_state: { stop: false, reason: nil },
      target_shape: { wildcard: true, redirect_cluster: false },
      all_found: Array.new(20) { |idx| "https://example.com/noise#{idx}" },
      low_confidence_found: Array.new(18) { |idx| "https://example.com/noise#{idx}" },
      adaptation_state: { last_window: { prioritized_gain: 0 } }
    }

    DirectoryEnum.apply_marginal_value_stop!(runtime)

    assert runtime[:stop_state][:stop]
    assert_match(/marginal directory value collapsed/, runtime[:stop_state][:reason])
  end

  private

  def lazy_scan(words:, filext: '')
    plan = DirectoryEnum.build_scan_plan(target: 'https://example.com', words: words, filext: filext, ctx: nil)
    plan[:seed_urls] = ['https://example.com/robots.txt']
    {
      normalized_target: 'https://example.com',
      url_plan: plan
    }
  end

  def extension_runtime(count:, found:, all_found:, low_confidence_found:)
    {
      count: count,
      found: found,
      all_found: all_found,
      low_confidence_found: low_confidence_found,
      extension_state: { enabled: false, reason: nil, checked_at: 0 },
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
