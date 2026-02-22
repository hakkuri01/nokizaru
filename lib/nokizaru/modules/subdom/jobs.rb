# frozen_string_literal: true

module Nokizaru
  module Modules
    # Job descriptor helpers for subdomain source scheduling
    module Subdomains
      module_function

      JOBS_WITHOUT_CONF = [
        ['AnubisDB', ->(host, _conf, http, out) { SubdomainModules::AnubisDB.call(host, http, out) }],
        ['ThreatMiner', ->(host, _conf, http, out) { SubdomainModules::ThreatMiner.call(host, http, out) }],
        ['CertSpotter', ->(host, _conf, http, out) { SubdomainModules::CertSpotter.call(host, http, out) }],
        ['HackerTarget', ->(host, _conf, http, out) { SubdomainModules::HackerTarget.call(host, http, out) }],
        ['crt.sh', ->(host, _conf, http, out) { SubdomainModules::CrtSh.call(host, http, out) }],
        ['UrlScan', ->(host, _conf, http, out) { SubdomainModules::UrlScan.call(host, http, out) }],
        ['AlienVault', ->(host, _conf, http, out) { SubdomainModules::AlienVault.call(host, http, out) }]
      ].freeze

      JOBS_WITH_CONF = [
        ['BeVigil', ->(host, conf, http, out) { SubdomainModules::BeVigil.call(host, conf, http, out) }],
        ['Facebook', ->(host, conf, http, out) { SubdomainModules::FacebookCT.call(host, conf, http, out) }],
        ['VirusTotal', ->(host, conf, http, out) { SubdomainModules::VirusTotal.call(host, conf, http, out) }],
        ['Shodan', ->(host, conf, http, out) { SubdomainModules::Shodan.call(host, conf, http, out) }],
        ['BinaryEdge', ->(host, conf, http, out) { SubdomainModules::BinaryEdge.call(host, conf, http, out) }],
        ['ZoomEye', ->(host, conf, http, out) { SubdomainModules::ZoomEye.call(host, conf, http, out) }],
        ['Netlas', ->(host, conf, http, out) { SubdomainModules::Netlas.call(host, conf, http, out) }],
        ['Hunter', ->(host, conf, http, out) { SubdomainModules::Hunter.call(host, conf, http, out) }],
        ['Chaos', ->(host, conf, http, out) { SubdomainModules::Chaos.call(host, conf, http, out) }],
        ['Censys', ->(host, conf, http, out) { SubdomainModules::Censys.call(host, conf, http, out) }]
      ].freeze

      def subdomain_jobs(hostname, conf_path, found)
        build_jobs(JOBS_WITHOUT_CONF, hostname, conf_path,
                   found) + build_jobs(JOBS_WITH_CONF, hostname, conf_path, found)
      end

      def build_jobs(definitions, hostname, conf_path, found)
        definitions.map { |name, fn| [name, proc { |http| fn.call(hostname, conf_path, http, found) }] }
      end
    end
  end
end
