# frozen_string_literal: true

require 'socket'
require 'concurrent'
require_relative '../log'
require_relative 'portscan/port_list'
require_relative 'portscan/nonblocking_scanner'

module Nokizaru
  module Modules
    # Nokizaru::Modules::PortScan implementation
    module PortScan
      module_function

      DEFAULT_CONNECT_TIMEOUT = 1
      CUSTOM_CONNECT_TIMEOUT = 0.5
      DEFAULT_RETRIES = 1
      DEFAULT_VERIFY = true
      DEFAULT_RATE_PER_SECOND = 200.0
      PROGRESS_PORT_INTERVAL = 50
      PROGRESS_TIME_INTERVAL = 0.1
      LARGE_SCAN_CONCURRENCY_MULTIPLIER = 20
      LARGE_SCAN_MAX_CONCURRENCY = 1024
      ALL_OPEN_MIN_PORTS = 25
      ALL_OPEN_RATIO = 0.75
      ALL_OPEN_LATENCY_CV_MAX = 0.35
      DEFAULT_PORT_SPECS = %w[top default 100].freeze
      ALL_PORT_SPEC = 'all'
      TLS_PORTS = [443, 465, 636, 990, 993, 995, 2376, 4443, 6443, 8443].freeze
      HTTP_HINT_TOKENS = %w[http https proxy grafana jenkins sonarqube kibana webmin elasticsearch couchdb].freeze
      SENSITIVE_PORTS = [2375, 27_017, 6379, 9200, 11_211].freeze
      SERVICE_CATEGORIES = {
        web: %w[HTTP HTTPS Proxy Grafana Jenkins SonarQube Kibana Webmin Elasticsearch CouchDB Kubernetes Docker],
        remote_access: %w[SSH Telnet RDP VNC TeamViewer],
        database: %w[MySQL PostgreSQL MongoDB Redis Oracle CouchDB Elasticsearch InfluxDB],
        mail: %w[SMTP SMTPS POP3 POP3S IMAP IMAPS],
        file_transfer: %w[FTP FTPS TFTP rsync NFS Subversion Git],
        messaging: %w[MQTT RabbitMQ Kafka ActiveMQ],
        dns: %w[DNS]
      }.freeze

      # Run this module and store normalized results in the run context
      def call(ip_addr, threads, ctx, port_spec: nil)
        result = { 'open_ports' => [], 'ports' => [] }
        entries = port_entries(port_spec)
        setup_scan_ui(threads, port_spec)
        scan_ports(ip_addr, threads, result, entries: entries, port_spec: port_spec)
        finalize_scan_output(result)
        save_scan_result(ctx, result)
      end

      def setup_scan_ui(threads, port_spec = nil)
        UI.module_header('Starting Port Scan...')
        UI.row(:plus, scan_label(port_spec), threads)
        puts
      end

      def scan_ports(ip_addr, threads, result, entries: nil, port_spec: nil)
        entries ||= port_entries(port_spec)
        tracker = build_scan_tracker(entries.length)
        result['total_ports'] = entries.length
        return scan_ports_nonblocking(ip_addr, threads, result, entries, tracker) unless default_port_spec?(port_spec)

        pool = Concurrent::FixedThreadPool.new(Integer(threads))
        entries.each { |port, name| pool.post { scan_port(ip_addr, port, name, result, tracker) } }
        pool.shutdown
        pool.wait_for_termination
      end

      def build_scan_tracker(total)
        {
          total: total,
          counter: Concurrent::AtomicFixnum.new(0),
          mutex: Mutex.new,
          progress_mutex: Mutex.new,
          rate_mutex: Mutex.new,
          rate_interval: 1.0 / DEFAULT_RATE_PER_SECOND,
          next_probe_at: 0.0,
          last_progress_at: 0.0
        }
      end

      def scan_ports_nonblocking(ip_addr, threads, result, entries, tracker)
        on_open = lambda do |port, name, latency_ms|
          record_found_port(ip_addr, port, name, latency_ms, result, tracker[:mutex])
        end
        NonblockingScanner.scan(
          ip_addr,
          entries,
          concurrency: large_scan_concurrency(threads),
          connect_timeout: CUSTOM_CONNECT_TIMEOUT,
          on_open: on_open,
          on_complete: -> { advance_scan_progress!(tracker) }
        )
      end

      def large_scan_concurrency(threads)
        requested = [Integer(threads), 1].max * LARGE_SCAN_CONCURRENCY_MULTIPLIER
        # Security: Bound socket fan-out to reduce local FD exhaustion and accidental traffic spikes
        [requested, LARGE_SCAN_MAX_CONCURRENCY, fd_safe_limit].min
      end

      def fd_safe_limit
        soft_limit = Process.getrlimit(Process::RLIMIT_NOFILE).first
        (soft_limit - 128).clamp(64, LARGE_SCAN_MAX_CONCURRENCY)
      rescue StandardError
        LARGE_SCAN_MAX_CONCURRENCY
      end

      def scan_port(ip_addr, port, name, result, tracker)
        throttle_probe!(tracker)
        record_open_port(ip_addr, port, name, result, tracker[:mutex])
      rescue StandardError
        nil
      ensure
        advance_scan_progress!(tracker)
      end

      def throttle_probe!(tracker)
        interval = tracker[:rate_interval].to_f
        return unless interval.positive?

        tracker[:rate_mutex].synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sleep_time = tracker[:next_probe_at] - now
          sleep(sleep_time) if sleep_time.positive?
          tracker[:next_probe_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + interval
        end
      end

      def record_open_port(ip_addr, port, name, result, mutex)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return unless open_port?(ip_addr, port)

        record_found_port(ip_addr, port, name, elapsed_ms(started_at), result, mutex)
      end

      def record_found_port(ip_addr, port, name, latency_ms, result, mutex)
        mutex.synchronize do
          puts("\r\e[K#{UI.prefix(:info)} #{UI::C}#{port} (#{name})#{UI::W}")
          result['open_ports'] << "#{port} (#{name})"
          result['ports'] << open_port_record(ip_addr, port, name, latency_ms)
        end
      end

      def advance_scan_progress!(tracker, force: false)
        progress = tracker[:counter].increment
        return unless force || progress == tracker[:total] || (progress % PROGRESS_PORT_INTERVAL).zero?

        tracker[:progress_mutex].synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          next unless force || progress == tracker[:total] || now - tracker[:last_progress_at] >= PROGRESS_TIME_INTERVAL

          print(UI.progress(:plus, 'Scanning', "#{progress}/#{tracker[:total]}"))
          tracker[:last_progress_at] = now
        end
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
      end

      def open_port_record(ip_addr, port, name, latency_ms)
        {
          'ip' => ip_addr.to_s,
          'port' => port.to_i,
          'protocol' => 'tcp',
          'state' => 'open',
          'service' => name.to_s,
          'source' => 'tcp_connect',
          'confidence' => 'confirmed',
          'latency_ms' => latency_ms
        }.merge(service_hints(port, name))
      end

      def service_hints(port, name)
        service_name = name.to_s
        {
          'category' => service_category(service_name),
          'tls_likely' => tls_likely?(port, service_name),
          'http_likely' => http_likely?(service_name),
          'exposure' => exposure_level(port),
          'enrichment' => 'port_metadata'
        }
      end

      def service_category(service_name)
        SERVICE_CATEGORIES.each do |category, tokens|
          return category.to_s if tokens.any? { |token| service_name.include?(token) }
        end

        'unknown'
      end

      def tls_likely?(port, service_name)
        TLS_PORTS.include?(port.to_i) || service_name.match?(/SSL|TLS|HTTPS|SMTPS|IMAPS|POP3S|LDAPS|FTPS/i)
      end

      def http_likely?(service_name)
        value = service_name.to_s.downcase
        HTTP_HINT_TOKENS.any? { |token| value.include?(token) }
      end

      def exposure_level(port)
        SENSITIVE_PORTS.include?(port.to_i) ? 'sensitive' : 'standard'
      end

      def finalize_scan_output(result)
        total = result['total_ports'] || PORT_LIST.length
        print(UI.progress(:plus, 'Scanning', "#{total}/#{total}"))
        puts
        UI.line(:info, 'Scan completed!')
        puts
        result['open_ports'].uniq!
        result['ports'] = unique_port_records(result['ports'])
        classify_portscan_shape!(result)
      end

      def unique_port_records(records)
        seen = {}
        Array(records).each_with_object([]) do |record, out|
          key = [record['ip'], record['protocol'], record['port']]
          next if seen[key]

          seen[key] = true
          out << record
        end
      end

      def classify_portscan_shape!(result)
        records = Array(result['ports'])
        total = result['total_ports'].to_i
        if all_open_or_tarpit?(records, total)
          result['network_shape'] = 'all_open_or_tarpit'
          result['shape_confidence'] = 'high'
          result['shape_reason'] = 'Implausibly broad TCP connect success with low latency variance'
          downgrade_tarpit_ports!(records)
        else
          result['network_shape'] = 'normal'
          result['shape_confidence'] = 'medium'
        end
      end

      def all_open_or_tarpit?(records, total)
        return false if total < ALL_OPEN_MIN_PORTS
        return false if ratio(records.length, total) < ALL_OPEN_RATIO

        latencies = records.filter_map { |record| record['latency_ms']&.to_f }.select(&:positive?)
        return false if latencies.length < ALL_OPEN_MIN_PORTS

        coefficient_of_variation(latencies) <= ALL_OPEN_LATENCY_CV_MAX
      end

      def downgrade_tarpit_ports!(records)
        records.each do |record|
          next if [80, 443].include?(record['port'].to_i)

          record['confidence'] = 'low'
          record['exposure'] = 'unverified'
          record['enrichment'] = 'port_metadata_tarpit_shape'
        end
      end

      def coefficient_of_variation(values)
        nums = Array(values).map(&:to_f).select(&:positive?)
        return 1.0 if nums.length < 2

        mean = nums.sum / nums.length
        variance = nums.sum { |value| (value - mean)**2 } / nums.length
        Math.sqrt(variance) / mean
      end

      def ratio(numerator, denominator)
        return 0.0 unless denominator.to_f.positive?

        numerator.to_f / denominator
      end

      def save_scan_result(ctx, result)
        ctx.run['modules']['portscan'] = result
        ctx.add_artifact('open_ports', artifact_ports(result))
        Log.write('[portscan] Completed')
      end

      def artifact_ports(result)
        structured = Array(result['ports']).filter_map do |record|
          next if record['confidence'].to_s == 'low'

          record['port']&.to_s
        end
        return structured unless structured.empty?

        Array(result['open_ports']).map { |item| item.to_s.split.first }
      end

      def port_entries(port_spec = nil)
        return PORT_LIST if default_port_spec?(port_spec)
        return all_port_entries if all_port_spec?(port_spec)

        parse_port_spec(port_spec).to_h do |port|
          [port, PORT_LIST.fetch(port, 'unknown')]
        end
      end

      def default_port_spec?(port_spec)
        value = port_spec.to_s.strip.downcase
        value.empty? || DEFAULT_PORT_SPECS.include?(value)
      end

      def scan_label(port_spec)
        value = port_spec.to_s.strip
        return 'Scanning top 100+ ports with threads' if default_port_spec?(value)
        return 'Scanning all 65535 ports with threads' if all_port_spec?(value)
        return "Scanning ports #{value} with threads" if single_port_range_spec?(value)

        "Scanning custom ports #{value} with threads"
      end

      def single_port_range_spec?(value)
        value.match?(/\A\d+\s*-\s*\d+\z/)
      end

      def all_port_spec?(port_spec)
        port_spec.to_s.strip.downcase == ALL_PORT_SPEC
      end

      def all_port_entries
        (1..65_535).to_h { |port| [port, PORT_LIST.fetch(port, 'unknown')] }
      end

      def parse_port_spec(port_spec)
        return (1..65_535).to_a if all_port_spec?(port_spec)

        ports = port_spec.to_s.split(',').flat_map { |part| expand_port_part(part) }
        ports.uniq.sort
      end

      def expand_port_part(part)
        value = part.to_s.strip
        return [] if value.empty?

        if value.include?('-')
          expand_port_range(value)
        else
          [validated_port(value)]
        end
      end

      def expand_port_range(value)
        first, last = value.split('-', 2).map { |item| validated_port(item) }
        raise ArgumentError, "Invalid descending port range: #{value}" if first > last

        (first..last).to_a
      end

      def validated_port(value)
        port = Integer(value)
        return port if port.between?(1, 65_535)

        raise ArgumentError, "Invalid TCP port: #{value}"
      rescue ArgumentError
        raise ArgumentError, "Invalid TCP port: #{value}"
      end

      # Probe a single port quickly and report only confirmed open sockets
      def open_port?(ip, port, retries: DEFAULT_RETRIES, verify: DEFAULT_VERIFY,
                     connect_timeout: DEFAULT_CONNECT_TIMEOUT)
        attempts = retries.to_i + 1
        attempts.times do
          next unless connect_once?(ip, port, connect_timeout)

          return true unless verify
          return true if connect_once?(ip, port, connect_timeout)
        end
        false
      end

      def connect_once?(ip, port, connect_timeout)
        socket = Socket.tcp(ip, port, connect_timeout: connect_timeout)
        socket.close
        true
      rescue StandardError
        false
      end
    end
  end
end
