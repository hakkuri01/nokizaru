# frozen_string_literal: true

require_relative '../http_client'

require_relative '../log'
require_relative '../keys'
require_relative '../version'
require_relative 'subdom/enumerator'
require_relative 'subdom/jobs'

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
    # Nokizaru::Modules::Subdomains implementation
    module Subdomains
      module_function

      DEFAULT_UA = "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)".freeze

      VALID = /^[A-Za-z0-9._~()'!*:@,;+?-]*$/

      # Run this module and store normalized results in the run context
      def call(hostname, timeout, ctx, conf_path)
        UI.module_header('Starting Sub-Domain Enumeration...')

        cache_key = ctx.cache&.key_for(['subdomains', hostname]) || "subdomains:#{hostname}"
        found = ctx.cache_fetch(cache_key, ttl_s: 43_200) do
          enumerate(hostname, timeout, conf_path)
        end
        found = Array(found).sort

        print_results(found)

        ctx.run['modules']['subdomains'] = { 'subdomains' => found }
        ctx.add_artifact('subdomains', found)

        Log.write('[subdom] Completed')
      end

      # Print a concise subdomain preview and final unique count
      def print_results(found)
        found = Array(found).sort

        if found.any?
          UI.line(:info, 'Results :')
          puts
          found.first(20).each { |u| puts(u) }
          UI.line(:info, 'Results truncated...') if found.length > 20
        end

        puts
        UI.row(:info, 'Total Unique Sub Domains Found', found.length)
      end
    end
  end
end
