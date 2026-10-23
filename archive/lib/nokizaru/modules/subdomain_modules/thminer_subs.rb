# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::ThreatMiner implementation
      module ThreatMiner
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('ThreatMiner')
          process_threatminer_response(hostname, http, found)
          Log.write('[thminer_subs] Completed')
        end

        def process_threatminer_response(hostname, http, found)
          resp = http.get('https://api.threatminer.org/v2/domain.php', params: { q: hostname, rt: '5' })
          status = Base.safe_status(resp)
          return append_threatminer_subdomains(resp, found) if status == 200

          Base.print_status('ThreatMiner', resp)
          Log.write("[thminer_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('ThreatMiner', e)
          Log.write("[thminer_subs] Exception = #{e}")
        end

        def append_threatminer_subdomains(resp, found)
          subdomains = JSON.parse(Base.safe_body(resp))['results'] || []
          Base.found('ThreatMiner', subdomains.length)
          found.concat(subdomains)
        end
      end
    end
  end
end
