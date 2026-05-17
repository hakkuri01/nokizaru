# frozen_string_literal: true

require 'socket'

module Nokizaru
  module Modules
    module PortScan
      # High-throughput TCP connect scanner for custom and full port ranges
      module NonblockingScanner
        module_function

        def scan(ip_addr, entries, concurrency:, connect_timeout:, on_open:, on_complete:)
          queue = entries.to_a.each
          active = {}
          context = {
            ip_addr: ip_addr,
            concurrency: concurrency,
            connect_timeout: connect_timeout,
            on_open: on_open,
            on_complete: on_complete
          }

          loop do
            fill_active(queue, active, context)
            break if active.empty?

            reap_ready(active, on_open, on_complete)
            reap_expired(active, on_complete)
          end
        ensure
          close_active(active) if active
        end

        def fill_active(queue, active, context)
          while active.length < context[:concurrency]
            port, name = queue.next
            start_probe(active, port, name, context)
          end
        rescue StopIteration
          nil
        end

        def start_probe(active, port, name, context)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
          socket.connect_nonblock(Socket.sockaddr_in(port, context[:ip_addr]))
          context[:on_open].call(port, name, elapsed_ms(started_at))
          close_socket(socket)
          context[:on_complete].call
        rescue IO::WaitWritable
          active[socket] = {
            port: port,
            name: name,
            started_at: started_at,
            deadline_at: started_at + context[:connect_timeout].to_f
          }
        rescue StandardError
          close_socket(socket)
          context[:on_complete].call
        end

        def reap_ready(active, on_open, on_complete)
          timeout = next_select_timeout(active)
          ready = IO.select(nil, active.keys, nil, timeout)
          Array(ready&.fetch(1, [])).each do |socket|
            state = active.delete(socket)
            next unless state

            on_open.call(state[:port], state[:name], elapsed_ms(state[:started_at])) if connect_success?(socket)
            close_socket(socket)
            on_complete.call
          end
        end

        def reap_expired(active, on_complete)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          active.select { |_, state| state[:deadline_at] <= now }.each_key do |socket|
            active.delete(socket)
            close_socket(socket)
            on_complete.call
          end
        end

        def next_select_timeout(active)
          return 0.0 if active.empty?

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          [active.values.map { |state| state[:deadline_at] }.min - now, 0.0].max
        end

        def connect_success?(socket)
          socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int.zero?
        rescue StandardError
          false
        end

        def elapsed_ms(started_at)
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
        end

        def close_active(active)
          active.each_key { |socket| close_socket(socket) }
        end

        def close_socket(socket)
          socket&.close unless socket&.closed?
        rescue StandardError
          nil
        end
      end
    end
  end
end
