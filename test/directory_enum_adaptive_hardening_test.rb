# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumAdaptiveHardeningTest < Minitest::Test
  def test_pressure_downgrade_moves_full_to_seeded
    stop_state = { stop: false, mode: Nokizaru::Modules::DirectoryEnum::MODE_FULL }
    timeout_state = { current: 2.5, min: 1.5 }
    runtime = {
      adaptation_state: {
        pressure_streak: Nokizaru::Modules::DirectoryEnum::PRESSURE_SEEDED_STREAK,
        low_yield_streak: 0
      }
    }

    result = Nokizaru::Modules::DirectoryEnum.send(
      :apply_mode_downgrade!,
      220,
      {},
      stop_state,
      timeout_state,
      runtime: runtime
    )

    assert_equal :downgraded, result
    assert_equal Nokizaru::Modules::DirectoryEnum::MODE_SEEDED, stop_state[:mode]
    assert_equal Nokizaru::Modules::DirectoryEnum::MODE_BUDGETS.fetch('seeded'), stop_state[:budgets]
  end

  def test_pressure_downgrade_moves_seeded_to_hostile_after_low_yield
    stop_state = { stop: false, mode: Nokizaru::Modules::DirectoryEnum::MODE_SEEDED }
    timeout_state = { current: 2.5, min: 1.5 }
    runtime = {
      adaptation_state: {
        pressure_streak: Nokizaru::Modules::DirectoryEnum::PRESSURE_HOSTILE_STREAK,
        low_yield_streak: Nokizaru::Modules::DirectoryEnum::LOW_YIELD_HOSTILE_STREAK
      }
    }

    result = Nokizaru::Modules::DirectoryEnum.send(
      :apply_mode_downgrade!,
      420,
      {},
      stop_state,
      timeout_state,
      runtime: runtime
    )

    assert_equal :downgraded, result
    assert_equal Nokizaru::Modules::DirectoryEnum::MODE_HOSTILE, stop_state[:mode]
    assert_equal :head, stop_state[:request_method]
  end

  def test_pressure_downgrade_stops_hostile_when_low_yield_is_sustained
    stop_state = { stop: false, mode: Nokizaru::Modules::DirectoryEnum::MODE_HOSTILE, reason: nil }
    timeout_state = { current: 1.5, min: 1.5 }
    runtime = {
      adaptation_state: {
        pressure_streak: Nokizaru::Modules::DirectoryEnum::PRESSURE_HOSTILE_STREAK,
        low_yield_streak: Nokizaru::Modules::DirectoryEnum::LOW_YIELD_STOP_STREAK
      }
    }

    result = Nokizaru::Modules::DirectoryEnum.send(
      :apply_mode_downgrade!,
      500,
      {},
      stop_state,
      timeout_state,
      runtime: runtime
    )

    assert_equal :stopped, result
    assert_equal true, stop_state[:stop]
    assert_match(/sustained hostile pressure/, stop_state[:reason])
  end

  def test_request_method_for_mode_uses_head_in_hostile
    assert_equal :head, Nokizaru::Modules::DirectoryEnum.send(:request_method_for_mode, 'hostile')
    assert_equal :get, Nokizaru::Modules::DirectoryEnum.send(:request_method_for_mode, 'full')
  end

  def test_apply_hostility_hint_only_softens_full_mode
    hint = { 'mode' => 'hostile' }

    assert_equal 'seeded', Nokizaru::Modules::DirectoryEnum.send(:apply_hostility_hint_mode, 'full', hint)
    assert_equal 'seeded', Nokizaru::Modules::DirectoryEnum.send(:apply_hostility_hint_mode, 'seeded', hint)
  end

  def test_workspace_hint_enabled_requires_workspace_and_cache
    with_workspace = Struct.new(:workspace, :cache).new(Object.new, Object.new)
    no_workspace = Struct.new(:workspace, :cache).new(nil, Object.new)

    assert_equal true, Nokizaru::Modules::DirectoryEnum.send(:workspace_hint_enabled?, with_workspace)
    assert_equal false, Nokizaru::Modules::DirectoryEnum.send(:workspace_hint_enabled?, no_workspace)
  end
end
