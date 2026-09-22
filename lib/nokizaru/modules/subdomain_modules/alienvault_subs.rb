# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::AlienVault implementation
      module AlienVault
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          key = Base.ensure_key('alienvault', 'NK_ALIENVAULT_KEY')
          return missing_alienvault_key unless key

          Base.requesting('AlienVault')
          process_alienvault_response(hostname, key, http, found)
          Log.write('[alienvault_subs] Completed')
        end

        def missing_alienvault_key
          Base.skipping('AlienVault', 'API key not found!')
          Log.write('[alienvault_subs] API key not found')
        end

        def process_alienvault_response(hostname, key, http, found)
          url = "https://otx.alienvault.com/api/v1/indicators/domain/#{hostname}/passive_dns"
          resp = http.get(url, headers: { 'X-OTX-API-KEY' => key })
          status = Base.safe_status(resp)
          return handle_alienvault_error(resp, status) unless status == 200

          subs = extract_alienvault_subdomains(resp)
          found.concat(subs)
          Base.found('AlienVault', subs.length)
        rescue StandardError => e
          Base.exception('AlienVault', e)
          Log.write("[alienvault_subs] Exception = #{e}")
        end

        def extract_alienvault_subdomains(resp)
          passive = JSON.parse(Base.safe_body(resp))['passive_dns'] || []
          passive.filter_map { |entry| entry['hostname'] }.uniq
        end

        def handle_alienvault_error(resp, status)
          Base.print_status('AlienVault', resp)
          Log.write("[alienvault_subs] Status = #{status.inspect}, expected 200")
        end
      end
    end
  end
end
