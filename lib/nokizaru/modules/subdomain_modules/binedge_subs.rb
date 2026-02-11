# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module BinaryEdge
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('binedge', conf_path, 'NK_BINEDGE_KEY')
          if key
            Base.requesting('BinaryEdge')
            url = "https://api.binaryedge.io/v2/query/domains/subdomain/#{hostname}"
            header = { 'X-key' => key }
            begin
              resp = http.get(url, headers: header)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                subs = json_data['events'] || []
                Base.found('binedge', subs.length)
                found.concat(subs)
              else
                Base.status_error('binedge', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[binedge_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('binedge', e)
              Log.write("[binedge_subs] Exception = #{e}")
            end
          else
            Base.skipping('binedge', 'API key not found!')
            Log.write('[binedge_subs] API key not found')
          end
          Log.write('[binedge_subs] Completed')
        end
      end
    end
  end
end
