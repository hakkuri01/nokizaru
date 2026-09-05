# frozen_string_literal: true

module Nokizaru
  module Modules
    module Subdomains
      module_function

      JOBS = [
        ['AnubisDB', ->(host, http, out) { SubdomainModules::AnubisDB.call(host, http, out) }],
        ['ThreatMiner', ->(host, http, out) { SubdomainModules::ThreatMiner.call(host, http, out) }],
        ['CertSpotter', ->(host, http, out) { SubdomainModules::CertSpotter.call(host, http, out) }],
        ['HackerTarget', ->(host, http, out) { SubdomainModules::HackerTarget.call(host, http, out) }],
        ['crt.sh', ->(host, http, out) { SubdomainModules::CrtSh.call(host, http, out) }],
        ['UrlScan', ->(host, http, out) { SubdomainModules::UrlScan.call(host, http, out) }],
        ['AlienVault', ->(host, http, out) { SubdomainModules::AlienVault.call(host, http, out) }],
        ['BeVigil', ->(host, http, out) { SubdomainModules::BeVigil.call(host, http, out) }],
        ['Facebook', ->(host, http, out) { SubdomainModules::FacebookCT.call(host, http, out) }],
        ['VirusTotal', ->(host, http, out) { SubdomainModules::VirusTotal.call(host, http, out) }],
        ['Shodan', ->(host, http, out) { SubdomainModules::Shodan.call(host, http, out) }],
        ['BinaryEdge', ->(host, http, out) { SubdomainModules::BinaryEdge.call(host, http, out) }],
        ['ZoomEye', ->(host, http, out) { SubdomainModules::ZoomEye.call(host, http, out) }],
        ['Netlas', ->(host, http, out) { SubdomainModules::Netlas.call(host, http, out) }],
        ['Hunter', ->(host, http, out) { SubdomainModules::Hunter.call(host, http, out) }],
        ['Chaos', ->(host, http, out) { SubdomainModules::Chaos.call(host, http, out) }],
        ['Censys', ->(host, http, out) { SubdomainModules::Censys.call(host, http, out) }]
      ].freeze

      def subdomain_jobs(hostname, found)
        JOBS.map { |name, fn| [name, proc { |http| fn.call(hostname, http, found) }] }
      end

      def subdomain_provider_names
        JOBS.map(&:first)
      end
    end
  end
end
