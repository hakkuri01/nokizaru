# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::Chaos implementation
      module Chaos
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('chaos', conf_path, 'NK_CHAOS_KEY')
          return missing_chaos_key unless key

          Base.requesting('Chaos')
          process_chaos_response(hostname, key, http, found)
          Log.write('[chaos_subs] Completed')
        end

        def missing_chaos_key
          Base.skipping('Chaos', 'API key not found!')
          Log.write('[chaos_subs] API key not found')
        end

        def process_chaos_response(hostname, key, http, found)
          headers = { 'Authorization' => key }
          resp = http.get("https://dns.projectdiscovery.io/dns/#{hostname}/subdomains", headers: headers)
          status = Base.safe_status(resp)
          return append_chaos_subdomains(resp, hostname, found) if status == 200

          Base.status_error('Chaos', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[chaos_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('Chaos', e)
          Log.write("[chaos_subs] Exception = #{e}")
        end

        def append_chaos_subdomains(resp, hostname, found)
          labels = Array(JSON.parse(Base.safe_body(resp))['subdomains']).map(&:to_s).reject(&:empty?)
          subs = labels.map { |label| "#{label}.#{hostname}" }
          Base.found('Chaos', subs.length)
          found.concat(subs)
        end
      end
    end
  end
end
