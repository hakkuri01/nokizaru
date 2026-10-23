require "json"
require "./scanner"

module Nokizaru
  module Portscan
    # One open TCP port as the Ruby `ports` record: the connect facts plus the
    # derived service hints, serialized flat (field order matches the Ruby hash)
    # to meet the parity contract. confidence/exposure/enrichment are rewritten
    # in place by downgrade_tarpit! when the whole scan looks like a tarpit.
    class PortRecord
      include JSON::Serializable

      WEB_PORTS        = Set{80, 443}
      TLS_PORTS        = Set{443, 465, 636, 990, 993, 995, 2376, 4443, 6443, 8443}
      SENSITIVE_PORTS  = Set{2375, 27017, 6379, 9200, 11211}
      HTTP_HINT_TOKENS = %w[http https proxy grafana jenkins sonarqube kibana webmin elasticsearch couchdb]
      TLS_NAME         = /SSL|TLS|HTTPS|SMTPS|IMAPS|POP3S|LDAPS|FTPS/i

      # Category tokens checked in order (web wins ties), matched as substrings
      # of the service name. Ports SERVICE_CATEGORIES.
      SERVICE_CATEGORIES = {
        "web"           => %w[HTTP HTTPS Proxy Grafana Jenkins SonarQube Kibana Webmin Elasticsearch CouchDB Kubernetes Docker],
        "remote_access" => %w[SSH Telnet RDP VNC TeamViewer],
        "database"      => %w[MySQL PostgreSQL MongoDB Redis Oracle CouchDB Elasticsearch InfluxDB],
        "mail"          => %w[SMTP SMTPS POP3 POP3S IMAP IMAPS],
        "file_transfer" => %w[FTP FTPS TFTP rsync NFS Subversion Git],
        "messaging"     => %w[MQTT RabbitMQ Kafka ActiveMQ],
        "dns"           => %w[DNS],
      }

      getter ip : String
      getter port : Int32
      getter protocol : String
      getter state : String
      getter service : String
      getter source : String
      getter confidence : String
      getter latency_ms : Float64
      getter category : String
      getter? tls_likely : Bool
      getter? http_likely : Bool
      getter exposure : String
      getter enrichment : String

      def initialize(
        @ip : String, @port : Int32, @protocol : String, @state : String,
        @service : String, @source : String, @confidence : String,
        @latency_ms : Float64, @category : String, @tls_likely : Bool,
        @http_likely : Bool, @exposure : String, @enrichment : String,
      )
      end

      def self.build(ip : String, open : OpenPort) : PortRecord
        service = open.name
        new(
          ip, open.port, "tcp", "open", service, "tcp_connect", "confirmed",
          open.latency_ms, category(service), tls_likely?(open.port, service),
          http_likely?(service), exposure(open.port), "port_metadata"
        )
      end

      def label : String
        "#{@port} (#{@service})"
      end

      # A tarpit-shaped scan accepts every connect, so a non-web open port is not
      # trustworthy; downgrade it. Web ports (80/443) keep their confidence since
      # a real web server is the common reason a broad scan still answers them.
      def downgrade_tarpit! : Nil
        return if WEB_PORTS.includes?(@port)

        @confidence = "low"
        @exposure = "unverified"
        @enrichment = "port_metadata_tarpit_shape"
      end

      private def self.category(service : String) : String
        SERVICE_CATEGORIES.each do |name, tokens|
          return name if tokens.any? { |token| service.includes?(token) }
        end
        "unknown"
      end

      private def self.tls_likely?(port : Int32, service : String) : Bool
        TLS_PORTS.includes?(port) || service.matches?(TLS_NAME)
      end

      private def self.http_likely?(service : String) : Bool
        value = service.downcase
        HTTP_HINT_TOKENS.any? { |token| value.includes?(token) }
      end

      private def self.exposure(port : Int32) : String
        SENSITIVE_PORTS.includes?(port) ? "sensitive" : "standard"
      end
    end
  end
end
