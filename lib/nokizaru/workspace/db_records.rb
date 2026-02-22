# frozen_string_literal: true

module Nokizaru
  class Workspace
    # Record import and snapshot helper methods for workspace DB operations
    module DBRecords
      include DBPortRecords

      private

      def normalized_run_hash(run_hash)
        run = run_hash || {}
        {
          'meta' => run['meta'] || {},
          'artifacts' => run['artifacts'] || {},
          'modules' => run['modules'] || {}
        }
      end

      def ingest_primary_identifiers(meta)
        host = meta['hostname'].to_s.strip
        ip = meta['ip'].to_s.strip
        import_hostname(host) unless host.empty?
        return nil if ip.empty?

        import_ip(ip)
      end

      def ingest_artifact_hostnames(artifacts)
        Array(artifacts['subdomains']).each { |host| import_hostname(host) }
      end

      def ingest_artifact_urls(artifacts, modules)
        artifact_urls(artifacts).each { |url| import_url(url) }
        crawler_urls(modules).each { |url| import_url(url) }
      end

      def artifact_urls(artifacts)
        Array(artifacts['urls']) + Array(artifacts['wayback_urls'])
      end

      def crawler_urls(modules)
        crawler = modules['crawler']
        return [] unless crawler.is_a?(Hash)

        Array(crawler['internal_links']) + Array(crawler['external_links'])
      end

      def add_snapshot_hostnames!(snapshot)
        return unless defined?(Ronin::DB::HostName)

        snapshot['hostnames'] = Ronin::DB::HostName.pluck(:name).sort
      end

      def add_snapshot_ip_addresses!(snapshot)
        return unless defined?(Ronin::DB::IPAddress)

        snapshot['ip_addresses'] = Ronin::DB::IPAddress.pluck(:address).sort
      end

      def add_snapshot_urls!(snapshot)
        return unless defined?(Ronin::DB::URL)

        snapshot['urls'] = Ronin::DB::URL.all.map(&:to_s).uniq.sort
      end

      def add_snapshot_open_ports!(snapshot)
        return unless defined?(Ronin::DB::OpenPort)

        entries = Ronin::DB::OpenPort.all.filter_map { |open_port| serialize_open_port(open_port) }
        snapshot['open_ports'] = entries.uniq.sort
      end

      def import_hostname(hostname)
        host = hostname.to_s.strip
        return if host.empty?
        return unless defined?(Ronin::DB::HostName)

        Ronin::DB::HostName.find_or_create_by(name: host)
      end

      def import_ip(ip_str)
        ip = ip_str.to_s.strip
        return nil if ip.empty?
        return nil unless defined?(Ronin::DB::IPAddress)

        Ronin::DB::IPAddress.find_or_create_by(address: ip)
      end

      def import_url(url_str)
        url = url_str.to_s.strip
        return if url.empty?
        return unless defined?(Ronin::DB::URL)

        Ronin::DB::URL.find_or_import(url) if Ronin::DB::URL.respond_to?(:find_or_import)
      rescue StandardError
        nil
      end
    end
  end
end
