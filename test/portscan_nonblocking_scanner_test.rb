# frozen_string_literal: true

require_relative 'test_helper'

class PortscanNonblockingScannerTest < Minitest::Test
  Scanner = Nokizaru::Modules::PortScan::NonblockingScanner

  def test_next_select_timeout_returns_zero_for_empty_or_expired_active_set
    assert_equal 0.0, Scanner.next_select_timeout({})

    socket = FakeSocket.new
    active = { socket => { deadline_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0 } }

    assert_equal 0.0, Scanner.next_select_timeout(active)
  end

  def test_reap_expired_closes_sockets_and_calls_complete
    socket = FakeSocket.new
    completed = 0
    active = { socket => { deadline_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0 } }

    Scanner.reap_expired(active, proc { completed += 1 })

    assert_empty active
    assert socket.closed?
    assert_equal 1, completed
  end

  def test_close_active_and_close_socket_tolerate_closed_or_nil_sockets
    open_socket = FakeSocket.new
    closed_socket = FakeSocket.new(closed: true)

    Scanner.close_active(open_socket => {}, closed_socket => {})
    Scanner.close_socket(nil)

    assert open_socket.closed?
    assert closed_socket.closed?
  end

  def test_connect_success_handles_socket_error_values_and_exceptions
    assert Scanner.connect_success?(FakeConnectSocket.new(0))
    refute Scanner.connect_success?(FakeConnectSocket.new(111))
    refute Scanner.connect_success?(FakeConnectSocket.new(:raise))
  end

  def test_elapsed_ms_returns_non_negative_duration
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.001

    assert_operator Scanner.elapsed_ms(started_at), :>=, 0.0
  end

  class FakeSocket
    def initialize(closed: false)
      @closed = closed
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  class FakeConnectSocket
    def initialize(error_code)
      @error_code = error_code
    end

    def getsockopt(_level, _name)
      raise 'getsockopt failed' if @error_code == :raise

      SocketOption.new(@error_code)
    end
  end

  class SocketOption
    def initialize(value)
      @value = value
    end

    def int
      @value
    end
  end
end
