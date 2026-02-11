# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module Netlas
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('netlas', conf_path, 'NK_NETLAS_KEY')

          if key
            Base.requesting('Netlas')
            url = 'https://app.netlas.io/api/domains/download/'
            headers = { 'X-API-Key' => key, 'Content-Type' => 'application/json' }
            payload = {
              q: "domain: *.#{hostname}",
              fields: ['domain'],
              source_type: 'include',
              size: '200'
            }

            begin
              resp = http.post(url, headers: headers, body: JSON.generate(payload))
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                subs = []
                json_data.each do |entry|
                  sub = entry.dig('data', 'domain')
                  subs << sub if sub
                end
                Base.found('netlas', subs.length)
                found.concat(subs)
              else
                Base.status_error('netlas', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[netlas_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('netlas', e)
              Log.write("[netlas_subs] Exception = #{e}")
            end
          else
            Base.skipping('netlas', 'API key not found!')
            Log.write('[netlas_subs] API key not found')
          end

          Log.write('[netlas_subs] Completed')
        end
      end
    end
  end
end
