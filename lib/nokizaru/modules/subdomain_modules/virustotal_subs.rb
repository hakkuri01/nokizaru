# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module VirusTotal
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          vt_key = Base.ensure_key('virustotal', conf_path, 'NK_VT_KEY')

          if vt_key
            Base.requesting('VirusTotal')
            url = "https://www.virustotal.com/api/v3/domains/#{hostname}/subdomains"
            headers = { 'x-apikey' => vt_key }
            begin
              resp = http.get(url, headers: headers)
              status = Base.safe_status(resp)
              if status == 200
                json_read = JSON.parse(Base.safe_body(resp))
                domains = json_read['data'] || []
                tmp = domains.map { |d| d['id'] }.compact
                Base.found('VirusTotal', tmp.length)
                found.concat(tmp)
              else
                Base.status_error('VirusTotal', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[virustotal_subs] Status = #{status}")
              end
            rescue StandardError => e
              Base.exception('VirusTotal', e)
              Log.write("[virustotal_subs] Exception = #{e}")
            end
          else
            Base.skipping('VirusTotal', 'API key not found!')
            Log.write('[virustotal_subs] API key not found')
          end

          Log.write('[virustotal_subs] Completed')
        end
      end
    end
  end
end
