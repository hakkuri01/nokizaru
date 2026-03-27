# frozen_string_literal: true

require 'timeout'

require_relative 'test_helper'

class DirectoryEnumStallWatchdogTest < Minitest::Test
  def test_stall_watchdog_stops_scan_when_activity_stalls
    runtime = {
      mutex: Mutex.new,
      stop_state: { stop: false, reason: nil },
      activity_state: {
        last_activity_at_mono: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0,
        stall_timeout_s: 0.05,
        watchdog_active: false,
        watchdog_stop: false,
        watchdog_thread: nil,
        tripped: false
      },
      count: 0,
      stats: { success: 0, errors: 0 }
    }
    scan = { total_urls: 100 }

    Nokizaru::Modules::DirectoryEnum.stub(:print_progress, nil) do
      Nokizaru::Modules::DirectoryEnum.send(:start_stall_watchdog!, runtime, scan)

      Timeout.timeout(1.0) do
        sleep(0.02) until runtime[:stop_state][:stop]
      end
    ensure
      Nokizaru::Modules::DirectoryEnum.send(:stop_stall_watchdog!, runtime)
    end

    assert_equal true, runtime.dig(:activity_state, :tripped)
    assert_match(/inactivity budget hit/, runtime.dig(:stop_state, :reason))
  end
end
