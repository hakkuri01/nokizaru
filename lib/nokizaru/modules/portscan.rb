# frozen_string_literal: true

require 'socket'
require 'concurrent'
require_relative '../log'
require_relative 'portscan/port_list'

module Nokizaru
  module Modules
    # Nokizaru::Modules::PortScan implementation
    module PortScan
      module_function

      # Run this module and store normalized results in the run context
      def call(ip_addr, threads, ctx)
        result = { 'open_ports' => [] }
        setup_scan_ui(threads)
        scan_ports(ip_addr, threads, result)
        finalize_scan_output(result)
        save_scan_result(ctx, result)
      end

      def setup_scan_ui(threads)
        UI.module_header('Starting Port Scan...')
        UI.row(:plus, 'Scanning Top 100+ Ports With Threads', threads)
        puts
      end

      def scan_ports(ip_addr, threads, result)
        tracker = build_scan_tracker
        pool = Concurrent::FixedThreadPool.new(Integer(threads))
        PORT_LIST.each { |port, name| pool.post { scan_port(ip_addr, port, name, result, tracker) } }
        pool.shutdown
        pool.wait_for_termination
      end

      def build_scan_tracker
        {
          total: PORT_LIST.length,
          counter: Concurrent::AtomicFixnum.new(0),
          mutex: Mutex.new
        }
      end

      def scan_port(ip_addr, port, name, result, tracker)
        record_open_port(ip_addr, port, name, result, tracker[:mutex])
      rescue StandardError
        nil
      ensure
        progress = tracker[:counter].increment
        print(UI.progress(:plus, 'Scanning', "#{progress}/#{tracker[:total]}"))
      end

      def record_open_port(ip_addr, port, name, result, mutex)
        return unless open_port?(ip_addr, port)

        mutex.synchronize do
          puts("\r\e[K#{UI.prefix(:info)} #{UI::C}#{port} (#{name})#{UI::W}")
          result['open_ports'] << "#{port} (#{name})"
        end
      end

      def finalize_scan_output(result)
        total = PORT_LIST.length
        print(UI.progress(:plus, 'Scanning', "#{total}/#{total}"))
        puts
        UI.line(:info, 'Scan Completed!')
        puts
        result['open_ports'].uniq!
      end

      def save_scan_result(ctx, result)
        ctx.run['modules']['portscan'] = result
        ctx.add_artifact('open_ports', result['open_ports'].map { |item| item.to_s.split.first })
        Log.write('[portscan] Completed')
      end

      # Probe a single port quickly and report only confirmed open sockets
      def open_port?(ip, port)
        socket = Socket.tcp(ip, port, connect_timeout: 1)
        socket.close
        true
      rescue StandardError
        false
      end
    end
  end
end
