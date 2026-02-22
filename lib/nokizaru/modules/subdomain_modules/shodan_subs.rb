# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::Shodan implementation
      module Shodan
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          sho_key = Base.ensure_key('shodan', conf_path, 'NK_SHODAN_KEY')
          return missing_shodan_key unless sho_key

          Base.requesting('Shodan')
          process_shodan_response(hostname, sho_key, http, found)
          Log.write('[shodan_subs] Completed')
        end

        def missing_shodan_key
          Base.skipping('Shodan', 'API key not found!')
          Log.write('[shodan_subs] API key not found')
        end

        def process_shodan_response(hostname, sho_key, http, found)
          resp = http.get("https://api.shodan.io/dns/domain/#{hostname}?key=#{sho_key}")
          status = Base.safe_status(resp)
          return append_shodan_subdomains(resp, hostname, found) if status == 200

          Base.status_error('Shodan', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[shodan_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('Shodan', e)
          Log.write("[shodan_subs] Exception = #{e}")
        end

        def append_shodan_subdomains(resp, hostname, found)
          subs = JSON.parse(Base.safe_body(resp))['subdomains'] || []
          values = subs.map { |subdomain| "#{subdomain}.#{hostname}" }
          Base.found('Shodan', values.length)
          found.concat(values)
        end
      end
    end
  end
end
