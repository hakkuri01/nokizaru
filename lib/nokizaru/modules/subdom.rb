# frozen_string_literal: true

require_relative '../http_client'

require_relative '../log'
require_relative '../keys'
require_relative '../version'

require_relative 'subdomain_modules/bevigil_subs'
require_relative 'subdomain_modules/anubis_subs'
require_relative 'subdomain_modules/thminer_subs'
require_relative 'subdomain_modules/fb_subs'
require_relative 'subdomain_modules/virustotal_subs'
require_relative 'subdomain_modules/shodan_subs'
require_relative 'subdomain_modules/certspot_subs'
require_relative 'subdomain_modules/htarget_subs'
require_relative 'subdomain_modules/crtsh_subs'
require_relative 'subdomain_modules/binedge_subs'
require_relative 'subdomain_modules/zoomeye_subs'
require_relative 'subdomain_modules/netlas_subs'
require_relative 'subdomain_modules/hunter_subs'
require_relative 'subdomain_modules/urlscan_subs'
require_relative 'subdomain_modules/alienvault_subs'
require_relative 'subdomain_modules/chaos_subs'
require_relative 'subdomain_modules/censys_subs'

module Nokizaru
  module Modules
    module Subdomains
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      DEFAULT_UA = "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)"

      VALID = /^[A-Za-z0-9._~()'!*:@,;+?-]*$/

      # Run this module and store normalized results in the run context
      def call(hostname, timeout, ctx, conf_path)
        puts("\n#{Y}[!] Starting Sub-Domain Enumeration...#{W}\n\n")

        cache_key = ctx.cache&.key_for(['subdomains', hostname]) || "subdomains:#{hostname}"
        found = ctx.cache_fetch(cache_key, ttl_s: 43_200) do
          enumerate(hostname, timeout, conf_path)
        end

        print_results(found)

        ctx.run['modules']['subdomains'] = { 'subdomains' => found }
        ctx.add_artifact('subdomains', found)

        Log.write('[subdom] Completed')
      end

      # Print a concise subdomain preview and final unique count
      def print_results(found)
        if found.any?
          puts("\n#{G}[+] #{C}Results : #{W}\n\n")
          found.first(20).each { |u| puts(u) }
          puts("\n#{G}[+]#{C} Results truncated...#{W}") if found.length > 20
        end

        puts("\n#{G}[+] #{C}Total Unique Sub Domains Found : #{W}#{found.length}")
      end

      # Query passive providers concurrently and merge normalized subdomain results
      def enumerate(hostname, timeout, conf_path)
        # Query passive sources concurrently under a single overall timeout budget
        # Prevents a single vendor from stalling the whole scan
        # Also caps per-vendor timeouts to keep performance consistent across runs
        require 'concurrent'
        found = Concurrent::Array.new

        overall_budget = [[timeout.to_f, 30.0].min, 5.0].max
        vendor_default = [overall_budget, 12.0].min

        vendor_timeouts = {
          'AnubisDB' => [vendor_default, 10.0].min,
          'ThreatMiner' => [vendor_default, 8.0].min,
          'crt.sh' => [vendor_default, 8.0].min,
          'HackerTarget' => vendor_default,
          'CertSpotter' => vendor_default,
          'UrlScan' => vendor_default,
          'AlienVault' => [vendor_default, 8.0].min,
          'Chaos' => [vendor_default, 8.0].min,
          'Censys' => vendor_default
        }.freeze

        # Build a base HTTP client with connection pooling
        # Each vendor module will get a client derived from this base
        # Ensures all requests share persistent connections where possible
        base_http = Nokizaru::HTTPClient.build(
          timeout_s: vendor_default,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: true,
          persistent: true,
          verify_ssl: true
        )

        jobs = []
        jobs << ['BeVigil', proc { |h| SubdomainModules::BeVigil.call(hostname, conf_path, h, found) }]
        jobs << ['AnubisDB', proc { |h| SubdomainModules::AnubisDB.call(hostname, h, found) }]
        jobs << ['ThreatMiner', proc { |h| SubdomainModules::ThreatMiner.call(hostname, h, found) }]
        jobs << ['Facebook', proc { |h| SubdomainModules::FacebookCT.call(hostname, conf_path, h, found) }]
        jobs << ['VirusTotal', proc { |h| SubdomainModules::VirusTotal.call(hostname, conf_path, h, found) }]
        jobs << ['Shodan', proc { |h| SubdomainModules::Shodan.call(hostname, conf_path, h, found) }]
        jobs << ['CertSpotter', proc { |h| SubdomainModules::CertSpotter.call(hostname, h, found) }]
        jobs << ['HackerTarget', proc { |h| SubdomainModules::HackerTarget.call(hostname, h, found) }]
        jobs << ['crt.sh', proc { |h| SubdomainModules::CrtSh.call(hostname, h, found) }]
        jobs << ['BinaryEdge', proc { |h| SubdomainModules::BinaryEdge.call(hostname, conf_path, h, found) }]
        jobs << ['ZoomEye', proc { |h| SubdomainModules::ZoomEye.call(hostname, conf_path, h, found) }]
        jobs << ['Netlas', proc { |h| SubdomainModules::Netlas.call(hostname, conf_path, h, found) }]
        jobs << ['Hunter', proc { |h| SubdomainModules::Hunter.call(hostname, conf_path, h, found) }]
        jobs << ['UrlScan', proc { |h| SubdomainModules::UrlScan.call(hostname, h, found) }]
        jobs << ['AlienVault', proc { |h| SubdomainModules::AlienVault.call(hostname, h, found) }]
        jobs << ['Chaos', proc { |h| SubdomainModules::Chaos.call(hostname, conf_path, h, found) }]
        jobs << ['Censys', proc { |h| SubdomainModules::Censys.call(hostname, conf_path, h, found) }]

        # Small pool avoids hammering providers
        pool_size = [6, jobs.length].min
        q = Queue.new
        jobs.each { |j| q << j }

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + overall_budget

        workers = Array.new(pool_size) do
          Thread.new do
            loop do
              break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

              job = begin
                q.pop(true)
              rescue StandardError
                nil
              end
              break unless job

              name, fn = job
              t = vendor_timeouts[name] || vendor_default
              http = base_http.with(timeout: { connect_timeout: 5, read_timeout: t, write_timeout: 5,
                                               operation_timeout: t })
              begin
                fn.call(http)
              rescue StandardError => e
                # Vendor modules usually handle their own exceptions. This is a last resort
                puts("#{R}[-] #{C}#{name} Exception : #{W}#{e}")
                Log.write("[subdom.worker] #{name} unhandled exception = #{e}")
              end
            end
          end
        end

        workers.each(&:join)

        # Post-filtering
        found = found.to_a
        found.select! { |item| item.end_with?(hostname) }
        found.select! { |item| item.match?(VALID) }
        found.uniq!

        found
      end
    end
  end
end
