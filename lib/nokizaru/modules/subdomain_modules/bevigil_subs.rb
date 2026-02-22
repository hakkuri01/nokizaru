# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::BeVigil implementation
      module BeVigil
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('bevigil', conf_path, 'NK_BEVIGIL_KEY')
          return missing_bevigil_key unless key

          Base.requesting('BeVigil')
          process_bevigil_response(hostname, key, http, found)
          Log.write('[bevigil_subs] Completed')
        end

        def missing_bevigil_key
          Base.skipping('BeVigil', 'API key not found!')
          Log.write('[bevigil_subs] API key not found')
        end

        def process_bevigil_response(hostname, key, http, found)
          headers = { 'X-Access-Token' => key }
          resp = http.get("https://osint.bevigil.com/api/#{hostname}/subdomains/", headers: headers)
          status = Base.safe_status(resp)
          return append_bevigil_subdomains(resp, found) if status == 200

          Base.status_error('BeVigil', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[bevigil_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('BeVigil', e)
          Log.write("[bevigil_subs] Exception = #{e}")
        end

        def append_bevigil_subdomains(resp, found)
          subdomains = JSON.parse(Base.safe_body(resp))['subdomains'] || []
          Base.found('BeVigil', subdomains.length)
          found.concat(subdomains)
        end
      end
    end
  end
end
