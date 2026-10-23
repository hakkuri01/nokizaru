# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::CertSpotter implementation
      module CertSpotter
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('CertSpotter')
          process_certspot_response(hostname, http, found)
          Log.write('[certspot_subs] Completed')
        end

        def process_certspot_response(hostname, http, found)
          resp = http.get('https://api.certspotter.com/v1/issuances', params: certspot_params(hostname))
          status = Base.safe_status(resp)
          return append_certspot_subdomains(resp, found) if status == 200

          Base.status_error('CertSpotter', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[certspot_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('CertSpotter', e)
          Log.write("[certspot_subs] Exception = #{e}")
        end

        def certspot_params(hostname)
          { domain: hostname, expand: 'dns_names', include_subdomains: 'true' }
        end

        def append_certspot_subdomains(resp, found)
          json_read = JSON.parse(Base.safe_body(resp))
          Base.found('Certspotter', json_read.length)
          json_read.each { |entry| found.concat(entry['dns_names'] || []) }
        end
      end
    end
  end
end
