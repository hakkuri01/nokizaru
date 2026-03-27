# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumRuntimeAdaptationTest < Minitest::Test
  def test_handle_runtime_adaptation_tracks_replaced_client_for_safe_cleanup
    old_client = Object.new
    new_client = Object.new
    runtime = {
      count: 200,
      stats: { errors: 0 },
      stop_state: { request_timeout: 2.5 },
      timeout_state: { current: 2.5, min: 1.5 },
      client: old_client,
      retired_clients: []
    }

    Nokizaru::Modules::DirectoryEnum.stub(:maybe_stop!, nil) do
      Nokizaru::Modules::DirectoryEnum.stub(:apply_mode_downgrade!, :downgraded) do
        Nokizaru::Modules::DirectoryEnum.stub(:client_config, {}) do
          Nokizaru::Modules::DirectoryEnum.stub(:rebuild_client, [new_client, { current: 1.5, min: 1.5 }]) do
            Nokizaru::Modules::DirectoryEnum.send(:handle_runtime_adaptation!, {}, runtime)
          end
        end
      end
    end

    assert_same new_client, runtime[:client]
    assert_equal 1, runtime[:retired_clients].length
    assert_same old_client, runtime[:retired_clients].first
    assert_equal 1.5, runtime[:stop_state][:request_timeout]
  end
end
