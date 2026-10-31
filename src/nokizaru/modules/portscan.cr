require "json"
require "../portscan/scanner"
require "../portscan/port_record"
require "../progress_reporter"
require "../ui"

module Nokizaru
  module Modules
    # TCP connect port scan. Drives the low-level Nokizaru::Portscan::Scanner,
    # enriches each open port into a PortRecord, and flags a tarpit-shaped
    # result. Ports modules/portscan.rb; the two Ruby scan engines collapse into
    # the one fiber scanner, with the careful default-spec behavior (verify +
    # rate limit) and the fast custom/all behavior expressed through
    # Portscan::Options. Result shape matches the Ruby run hash (parity).
    module PortScan
      extend self

      DEFAULT_CONNECT_TIMEOUT =   1.0
      CUSTOM_CONNECT_TIMEOUT  =   0.5
      DEFAULT_RETRIES         =     1
      DEFAULT_RATE_PER_SECOND = 200.0

      # Tarpit heuristic thresholds (ports ALL_OPEN_*): a scan that accepts an
      # implausibly large fraction of ports with very uniform latency is almost
      # certainly a tarpit or an all-accept middlebox, not a real host.
      ALL_OPEN_MIN_PORTS      =   25
      ALL_OPEN_RATIO          = 0.75
      ALL_OPEN_LATENCY_CV_MAX = 0.35
      TARPIT_REASON           = "Implausibly broad TCP connect success with low latency variance"

      DEFAULT_PORT_SPECS = %w[top default 100]
      ALL_PORT_SPEC      = "all"
      MAX_PORT           = 65_535

      # port => service name, the default "top 100+" scan set. Ports PORT_LIST.
      PORT_LIST = {
        1 => "tcpmux", 9 => "Discard", 15 => "netstat", 20 => "FTP-CLI", 21 => "FTP", 22 => "SSH", 23 => "Telnet",
        25 => "SMTP", 26 => "rsftp", 53 => "DNS", 67 => "DHCP (Server)", 68 => "DHCP (Client)", 69 => "TFTP",
        80 => "HTTP", 110 => "POP3", 119 => "NNTP", 123 => "NTP", 135 => "Microsoft RPC",
        137 => "NetBIOS Name Service", 138 => "NetBIOS Datagram Service", 139 => "NetBIOS Session Service",
        143 => "IMAP", 161 => "SNMP", 162 => "SNMP Trap", 179 => "BGP", 194 => "IRC", 389 => "LDAP",
        443 => "HTTPS", 445 => "Microsoft-DS", 465 => "SMTPS", 515 => "LPD", 520 => "RIP",
        554 => "RTSP (Real-Time Streaming)", 587 => "SMTP (Submission)", 631 => "IPP (CUPS)", 636 => "LDAPS",
        873 => "rsync", 990 => "FTPS", 993 => "IMAPS", 995 => "POP3S", 1024 => "Dynamic/Private",
        1080 => "Socks Proxy", 1194 => "OpenVPN", 1433 => "Microsoft SQL Server", 1434 => "Microsoft SQL Monitor",
        1521 => "Oracle DB", 1701 => "L2TP", 1723 => "PPTP", 1883 => "MQTT", 2000 => "Cisco-sccp", 2049 => "NFS",
        2222 => "EtherNetIP-1", 2375 => "Docker REST API", 2376 => "Docker REST API (TLS)", 2483 => "Oracle DB",
        2484 => "Oracle DB (TLS)", 3000 => "Grafana", 3306 => "MySQL", 3389 => "RDP", 3690 => "Subversion",
        4373 => "Remote Authenticated Command", 4443 => "HTTPS-Alt", 4444 => "Metasploit",
        4567 => "MySQL Group Replication", 4786 => "Cisco Smart Install", 5060 => "SIP", 5044 => "Logstash",
        5432 => "PostgreSQL", 5555 => "Open Remote", 5672 => "RabbitMQ", 5900 => "VNC", 5938 => "TeamViewer",
        5984 => "CouchDB", 61_616 => "ActiveMQ", 6379 => "Redis", 6443 => "Kubernetes API", 6667 => "IRC",
        7000 => "Couchbase", 7200 => "Hazelcast", 8000 => "HTTP-Alt", 8008 => "HTTP-Alt", 8080 => "HTTP-Proxy",
        8081 => "SonarQube", 8086 => "InfluxDB", 8088 => "Kibana", 8181 => "HTTP-Alt", 8443 => "HTTPS-Alt",
        8444 => "Jenkins", 8888 => "HTTP-Alt", 9000 => "SonarQube", 9090 => "Openfire", 9092 => "Kafka",
        9093 => "Prometheus Alertmanager", 9200 => "Elasticsearch", 9300 => "Elasticsearch", 9418 => "Git",
        9990 => "JBoss Management", 9993 => "Unreal Tournament", 9999 => "NMAP", 10_000 => "Webmin",
        10_050 => "Zabbix Agent", 10_051 => "Zabbix Server", 11_211 => "Memcached", 11_300 => "Beanstalkd",
        25_565 => "Minecraft", 27_015 => "Source Engine Games", 27_017 => "MongoDB", 27_018 => "MongoDB",
        50_000 => "SAP", 50_030 => "Hadoop", 50_070 => "Hadoop",
      }

      # The per-module result; field order matches the Ruby hash. shape_reason is
      # omitted unless the scan was classified as a tarpit.
      class Result
        include JSON::Serializable

        getter open_ports : Array(String)
        getter ports : Array(Portscan::PortRecord)
        getter total_ports : Int32
        getter network_shape : String
        getter shape_confidence : String
        getter shape_reason : String?

        def initialize(
          @open_ports : Array(String),
          @ports : Array(Portscan::PortRecord),
          @total_ports : Int32,
          @network_shape : String,
          @shape_confidence : String,
          @shape_reason : String? = nil,
        )
        end

        # Open port numbers worth carrying forward, excluding tarpit-downgraded
        # ones. Ports artifact_ports.
        def artifact_ports : Array(String)
          @ports.compact_map { |record| record.port.to_s unless record.confidence == "low" }
        end
      end

      # Scans `ip` for the ports named by `spec` (default top-100, "all", or a
      # custom list/range). Complexity: O(entries) probes through the bounded
      # scanner, then O(entries) to enrich, sort, and classify.
      # Renders the open ports (cyan, as discovered) and a completion line for the
      # classic output and the dashboard capture. Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Port Scan")
        result.open_ports.each { |port| UI.line(:info, "#{UI::C}#{port}#{UI::W}") }
        UI.line(:info, "Scan completed!")
        UI.blank_line
      end

      def collect(ip : String, threads : Int32, spec : String? = nil, scanner : Portscan::Scanner = Portscan::Scanner.new, progress : ProgressReporter = ProgressReporter::NULL, stop : ScanStop = ScanStop.new) : Result
        entries = port_entries(spec)
        total = entries.size
        opens = scanner.scan(ip, entries, scan_options(threads, spec, stop), progress_callback(progress, total))
        build_result(ip, total, opens)
      end

      # Reports "<scanned>/<total> open <n>" per probe for the live rail, matching
      # the Ruby port scan. nil when no rail is listening, so the scanner skips
      # the per-probe counting entirely.
      private def progress_callback(progress : ProgressReporter, total : Int32) : Proc(Int32, Int32, Nil)?
        return nil unless progress.active?

        ->(scanned : Int32, open : Int32) { progress.report(detail: "#{scanned}/#{total} open #{open}") }
      end

      # The (port, name) pairs for a spec: the default set, all 65535, or the
      # parsed custom ports named from PORT_LIST (unknown ports get "unknown").
      def port_entries(spec : String? = nil) : Array({Int32, String})
        return PORT_LIST.map { |port, name| {port, name} } if default_spec?(spec)
        return (1..MAX_PORT).map { |port| {port, PORT_LIST[port]? || "unknown"} } if all_spec?(spec)

        parse_spec(spec).map { |port| {port, PORT_LIST[port]? || "unknown"} }
      end

      private def scan_options(threads : Int32, spec : String?, stop : ScanStop) : Portscan::Options
        return large_scan_options(threads, stop) unless default_spec?(spec)

        Portscan::Options.new(
          concurrency: {threads, 1}.max,
          connect_timeout: DEFAULT_CONNECT_TIMEOUT,
          retries: DEFAULT_RETRIES,
          verify: true,
          rate_per_second: DEFAULT_RATE_PER_SECOND,
          stop: stop,
        )
      end

      private def large_scan_options(threads : Int32, stop : ScanStop) : Portscan::Options
        Portscan::Options.new(
          concurrency: Portscan::Scanner.large_scan_concurrency(threads),
          connect_timeout: CUSTOM_CONNECT_TIMEOUT,
          retries: 0,
          verify: false,
          rate_per_second: 0.0,
          stop: stop,
        )
      end

      private def build_result(ip : String, total : Int32, opens : Array(Portscan::OpenPort)) : Result
        records = opens.map { |open| Portscan::PortRecord.build(ip, open) }.sort_by!(&.port)
        if tarpit?(records, total)
          records.each(&.downgrade_tarpit!)
          Result.new(records.map(&.label), records, total, "all_open_or_tarpit", "high", TARPIT_REASON)
        else
          Result.new(records.map(&.label), records, total, "normal", "medium")
        end
      end

      private def tarpit?(records : Array(Portscan::PortRecord), total : Int32) : Bool
        return false if total < ALL_OPEN_MIN_PORTS
        return false if ratio(records.size, total) < ALL_OPEN_RATIO

        latencies = records.map(&.latency_ms).select(&.positive?)
        return false if latencies.size < ALL_OPEN_MIN_PORTS

        coefficient_of_variation(latencies) <= ALL_OPEN_LATENCY_CV_MAX
      end

      private def ratio(numerator : Int32, denominator : Int32) : Float64
        denominator <= 0 ? 0.0 : numerator.to_f / denominator
      end

      private def coefficient_of_variation(values : Array(Float64)) : Float64
        return 1.0 if values.size < 2

        mean = values.sum / values.size
        return 1.0 if mean <= 0

        variance = values.sum { |value| (value - mean) ** 2 } / values.size
        Math.sqrt(variance) / mean
      end

      private def default_spec?(spec : String?) : Bool
        value = spec.to_s.strip.downcase
        value.empty? || DEFAULT_PORT_SPECS.includes?(value)
      end

      private def all_spec?(spec : String?) : Bool
        spec.to_s.strip.downcase == ALL_PORT_SPEC
      end

      private def parse_spec(spec : String?) : Array(Int32)
        ports = spec.to_s.split(',').flat_map { |part| expand_part(part) }
        ports.uniq!
        ports.sort!
      end

      private def expand_part(part : String) : Array(Int32)
        value = part.strip
        return [] of Int32 if value.empty?
        return expand_range(value) if value.includes?('-')

        [validated_port(value)]
      end

      private def expand_range(value : String) : Array(Int32)
        bounds = value.split('-', 2).map { |item| validated_port(item.strip) }
        first, last = bounds[0], bounds[1]
        raise ArgumentError.new("Invalid descending port range: #{value}") if first > last

        (first..last).to_a
      end

      private def validated_port(value : String) : Int32
        port = value.to_i?
        raise ArgumentError.new("Invalid TCP port: #{value}") if port.nil? || !(1..MAX_PORT).includes?(port)

        port
      end
    end
  end
end
