# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module BeVigil
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('bevigil', conf_path, 'NK_BEVIGIL_KEY')

          if key
            Base.requesting('BeVigil')
            url = "https://osint.bevigil.com/api/#{hostname}/subdomains/"
            header = { 'X-Access-Token' => key }

            begin
              resp = http.get(url, headers: header)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                subdomains = json_data['subdomains'] || []
                Base.found('BeVigil', subdomains.length)
                found.concat(subdomains)
              else
                Base.status_error('BeVigil', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[bevigil_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('BeVigil', e)
              Log.write("[bevigil_subs] Exception = #{e}")
            end
          else
            Base.skipping('BeVigil', 'API key not found!')
            Log.write('[bevigil_subs] API key not found')
          end

          Log.write('[bevigil_subs] Completed')
        end
      end
    end
  end
end
