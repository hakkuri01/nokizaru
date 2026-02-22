# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::Netlas implementation
      module Netlas
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('netlas', conf_path, 'NK_NETLAS_KEY')
          return missing_netlas_key unless key

          Base.requesting('Netlas')
          process_netlas_response(hostname, key, http, found)
          Log.write('[netlas_subs] Completed')
        end

        def missing_netlas_key
          Base.skipping('netlas', 'API key not found!')
          Log.write('[netlas_subs] API key not found')
        end

        def process_netlas_response(hostname, key, http, found)
          resp = http.post(netlas_url, headers: netlas_headers(key), body: JSON.generate(netlas_payload(hostname)))
          status = Base.safe_status(resp)
          return append_netlas_subdomains(resp, found) if status == 200

          Base.status_error('netlas', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[netlas_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('netlas', e)
          Log.write("[netlas_subs] Exception = #{e}")
        end

        def netlas_url
          'https://app.netlas.io/api/domains/download/'
        end

        def netlas_headers(key)
          { 'X-API-Key' => key, 'Content-Type' => 'application/json' }
        end

        def netlas_payload(hostname)
          { q: "domain: *.#{hostname}", fields: ['domain'], source_type: 'include', size: '200' }
        end

        def append_netlas_subdomains(resp, found)
          values = JSON.parse(Base.safe_body(resp)).filter_map { |entry| entry.dig('data', 'domain') }
          Base.found('netlas', values.length)
          found.concat(values)
        end
      end
    end
  end
end
