# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::BinaryEdge implementation
      module BinaryEdge
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('binedge', conf_path, 'NK_BINEDGE_KEY')
          return missing_binedge_key unless key

          Base.requesting('BinaryEdge')
          process_binedge_response(hostname, key, http, found)
          Log.write('[binedge_subs] Completed')
        end

        def missing_binedge_key
          Base.skipping('binedge', 'API key not found!')
          Log.write('[binedge_subs] API key not found')
        end

        def process_binedge_response(hostname, key, http, found)
          headers = { 'X-key' => key }
          resp = http.get("https://api.binaryedge.io/v2/query/domains/subdomain/#{hostname}", headers: headers)
          status = Base.safe_status(resp)
          return append_binedge_subdomains(resp, found) if status == 200

          Base.status_error('binedge', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[binedge_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('binedge', e)
          Log.write("[binedge_subs] Exception = #{e}")
        end

        def append_binedge_subdomains(resp, found)
          subs = JSON.parse(Base.safe_body(resp))['events'] || []
          Base.found('binedge', subs.length)
          found.concat(subs)
        end
      end
    end
  end
end
