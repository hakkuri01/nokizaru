# frozen_string_literal: true

require 'socket'
require_relative 'test_helper'

class PortScanTest < Minitest::Test
  PortScan = Nokizaru::Modules::PortScan

  def test_scan_label_defaults_to_top_ports
    assert_equal('Scanning top 100+ ports with threads', PortScan.scan_label(nil))
    assert_equal('Scanning top 100+ ports with threads', PortScan.scan_label('top'))
    assert_equal('Scanning top 100+ ports with threads', PortScan.scan_label('100'))
  end

  def test_scan_label_handles_all_ports
    assert_equal('Scanning all 65535 ports with threads', PortScan.scan_label('all'))
  end

  def test_scan_label_handles_single_range
    assert_equal('Scanning ports 1-65535 with threads', PortScan.scan_label('1-65535'))
  end

  def test_scan_label_preserves_custom_user_input
    spec = '80,443,1000-2000'

    assert_equal("Scanning custom ports #{spec} with threads", PortScan.scan_label(spec))
  end

  def test_setup_scan_ui_renders_dynamic_label
    output = capture_stdout { PortScan.setup_scan_ui(50, '80,443,1000-2000') }

    assert_includes(output, 'Scanning custom ports 80,443,1000-2000 with threads')
    assert_includes(output, '50')
  end

  def test_parse_port_spec_dedupes_and_sorts_ports
    assert_equal([22, 80, 443, 1000, 1001, 1002], PortScan.parse_port_spec('443,80,1000-1002,22,80'))
  end

  def test_parse_port_spec_accepts_all_ports
    ports = PortScan.parse_port_spec('all')

    assert_equal(65_535, ports.length)
    assert_equal(1, ports.first)
    assert_equal(65_535, ports.last)
  end

  def test_parse_port_spec_rejects_invalid_ports
    assert_raises(ArgumentError) { PortScan.parse_port_spec('0') }
    assert_raises(ArgumentError) { PortScan.parse_port_spec('65536') }
  end

  def test_parse_port_spec_rejects_descending_ranges
    assert_raises(ArgumentError) { PortScan.parse_port_spec('100-90') }
  end

  def test_custom_scan_detects_local_open_port_and_ignores_closed_port
    server = TCPServer.new('127.0.0.1', 0)
    open_port = server.addr[1]
    closed_port = unused_local_port
    accept_thread = accept_connections(server)
    result = { 'open_ports' => [], 'ports' => [] }

    capture_stdout do
      PortScan.scan_ports(
        '127.0.0.1',
        1,
        result,
        entries: { open_port => 'test-open', closed_port => 'test-closed' },
        port_spec: "#{open_port},#{closed_port}"
      )
    end

    assert_includes(result['open_ports'], "#{open_port} (test-open)")
    refute_includes(result['open_ports'], "#{closed_port} (test-closed)")

    record = result['ports'].find { |item| item['port'] == open_port }
    assert_equal('tcp', record['protocol'])
    assert_equal('open', record['state'])
    assert_equal('confirmed', record['confidence'])
  ensure
    server&.close
    accept_thread&.kill
    accept_thread&.join
  end

  def test_all_open_tarpit_shape_downgrades_non_web_ports
    result = {
      'total_ports' => 40,
      'open_ports' => [],
      'ports' => (1..35).map do |port|
        PortScan.open_port_record('203.0.113.10', port, "svc#{port}", 25.0 + (port % 3))
      end
    }

    PortScan.classify_portscan_shape!(result)

    assert_equal 'all_open_or_tarpit', result['network_shape']
    assert_equal 'high', result['shape_confidence']
    assert_equal 'low', result['ports'].find { |record| record['port'] == 22 }['confidence']
  end

  def test_artifact_ports_excludes_low_confidence_tarpit_ports
    result = {
      'ports' => [
        { 'port' => 80, 'confidence' => 'confirmed' },
        { 'port' => 22, 'confidence' => 'low' }
      ],
      'open_ports' => ['80 (HTTP)', '22 (SSH)']
    }

    assert_equal ['80'], PortScan.artifact_ports(result)
  end

  private

  def unused_local_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def accept_connections(server)
    Thread.new do
      loop do
        socket = server.accept
        socket.close
      rescue IOError, Errno::EBADF
        break
      end
    end
  end
end
