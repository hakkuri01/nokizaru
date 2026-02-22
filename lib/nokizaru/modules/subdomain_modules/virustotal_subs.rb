# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::VirusTotal implementation
      module VirusTotal
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          vt_key = Base.ensure_key('virustotal', conf_path, 'NK_VT_KEY')
          return missing_vt_key unless vt_key

          Base.requesting('VirusTotal')
          process_vt_response(hostname, vt_key, http, found)
          Log.write('[virustotal_subs] Completed')
        end

        def missing_vt_key
          Base.skipping('VirusTotal', 'API key not found!')
          Log.write('[virustotal_subs] API key not found')
        end

        def process_vt_response(hostname, vt_key, http, found)
          headers = { 'x-apikey' => vt_key }
          resp = http.get("https://www.virustotal.com/api/v3/domains/#{hostname}/subdomains", headers: headers)
          status = Base.safe_status(resp)
          return append_vt_subdomains(resp, found) if status == 200

          Base.status_error('VirusTotal', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[virustotal_subs] Status = #{status}")
        rescue StandardError => e
          Base.exception('VirusTotal', e)
          Log.write("[virustotal_subs] Exception = #{e}")
        end

        def append_vt_subdomains(resp, found)
          domains = JSON.parse(Base.safe_body(resp))['data'] || []
          values = domains.map { |entry| entry['id'] }.compact
          Base.found('VirusTotal', values.length)
          found.concat(values)
        end
      end
    end
  end
end
