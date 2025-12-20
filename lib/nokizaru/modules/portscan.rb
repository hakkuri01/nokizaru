# frozen_string_literal: true

require 'socket'
require 'concurrent'
require_relative 'export'
require_relative '../log'

module Nokizaru
  module Modules
    module PortScan
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      PORT_LIST = {
        1 => "tcpmux",
        9 => "Discard",
        15 => "netstat",
        20 => "FTP-CLI",
        21 => "FTP",
        22 => "SSH",
        23 => "Telnet",
        25 => "SMTP",
        26 => "rsftp",
        53 => "DNS",
        67 => "DHCP (Server)",
        68 => "DHCP (Client)",
        69 => "TFTP",
        80 => "HTTP",
        110 => "POP3",
        119 => "NNTP",
        123 => "NTP",
        135 => "Microsoft RPC",
        137 => "NetBIOS Name Service",
        138 => "NetBIOS Datagram Service",
        139 => "NetBIOS Session Service",
        143 => "IMAP",
        161 => "SNMP",
        162 => "SNMP Trap",
        179 => "BGP",
        194 => "IRC",
        389 => "LDAP",
        443 => "HTTPS",
        445 => "Microsoft-DS",
        465 => "SMTPS",
        515 => "LPD",
        520 => "RIP",
        554 => "RTSP (Real-Time Streaming)",
        587 => "SMTP (Submission)",
        631 => "IPP (CUPS)",
        636 => "LDAPS",
        873 => "rsync",
        990 => "FTPS",
        993 => "IMAPS",
        995 => "POP3S",
        1024 => "Dynamic/Private",
        1080 => "Socks Proxy",
        1194 => "OpenVPN",
        1433 => "Microsoft SQL Server",
        1434 => "Microsoft SQL Monitor",
        1521 => "Oracle DB",
        1701 => "L2TP",
        1723 => "PPTP",
        1883 => "MQTT",
        2000 => "Cisco-sccp",
        2049 => "NFS",
        2222 => "EtherNetIP-1",
        2375 => "Docker REST API",
        2376 => "Docker REST API (TLS)",
        2483 => "Oracle DB",
        2484 => "Oracle DB (TLS)",
        3000 => "Grafana",
        3306 => "MySQL",
        3389 => "RDP",
        3690 => "Subversion",
        4373 => "Remote Authenticated Command",
        4443 => "HTTPS-Alt",
        4444 => "Metasploit",
        4567 => "MySQL Group Replication",
        4786 => "Cisco Smart Install",
        5060 => "SIP",
        5044 => "Logstash",
        5432 => "PostgreSQL",
        5555 => "Open Remote",
        5672 => "RabbitMQ",
        5900 => "VNC",
        5938 => "TeamViewer",
        5984 => "CouchDB",
        61616 => "ActiveMQ",
        6379 => "Redis",
        6443 => "Kubernetes API",
        6667 => "IRC",
        7000 => "Couchbase",
        7200 => "Hazelcast",
        8000 => "HTTP-Alt",
        8008 => "HTTP-Alt",
        8080 => "HTTP-Proxy",
        8081 => "SonarQube",
        8086 => "InfluxDB",
        8088 => "Kibana",
        8181 => "HTTP-Alt",
        8443 => "HTTPS-Alt",
        8444 => "Jenkins",
        8888 => "HTTP-Alt",
        9000 => "SonarQube",
        9090 => "Openfire",
        9092 => "Kafka",
        9093 => "Prometheus Alertmanager",
        9200 => "Elasticsearch",
        9300 => "Elasticsearch",
        9418 => "Git",
        9990 => "JBoss Management",
        9993 => "Unreal Tournament",
        9999 => "NMAP",
        10_000 => "Webmin",
        10_050 => "Zabbix Agent",
        10_051 => "Zabbix Server",
        11_211 => "Memcached",
        11_300 => "Beanstalkd",
        25_565 => "Minecraft",
        27_015 => "Source Engine Games",
        27_017 => "MongoDB",
        27_018 => "MongoDB",
        50_000 => "SAP",
        50_030 => "Hadoop",
        50_070 => "Hadoop"
      }.freeze

      def call(ip_addr, output, data, threads)
        result = { 'ports' => [] }
        puts("\n#{Y}[!] Starting Port Scan...#{W}\n\n")
        puts("#{G}[+] #{C}Scanning Top 100+ Ports With #{threads} Threads...#{W}\n\n")

        total = PORT_LIST.length
        counter = Concurrent::AtomicFixnum.new(0)
        mutex = Mutex.new

        pool = Concurrent::FixedThreadPool.new(Integer(threads))

        PORT_LIST.each do |port, name|
          pool.post do
            begin
              if open_port?(ip_addr, port)
                mutex.synchronize do
                  puts("\e[K#{G}[+] #{C}#{port} (#{name})#{W}")
                  result['ports'] << "#{port} (#{name})"
                end
              end
            rescue StandardError
              # ignore
            ensure
              current = counter.increment
              print("#{Y}[!] #{C}Scanning : #{W}#{current}/#{total}\r")
            end
          end
        end

        pool.shutdown
        pool.wait_for_termination

        puts("\n#{G}[+] #{C}Scan Completed!#{W}\n\n")

        if output
          data['module-Port Scan'] = result
          result['exported'] = false
          fname = File.join(output[:directory], "ports.#{output[:format]}")
          output[:file] = fname
          Export.call(output, data)
        end

        Log.write('[portscan] Completed')
      end

      def open_port?(ip, port)
        Socket.tcp(ip, port, connect_timeout: 1) { |_s| }
        true
      rescue StandardError
        false
      end
    end
  end
end
