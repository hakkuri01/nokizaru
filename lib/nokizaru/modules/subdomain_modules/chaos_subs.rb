# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module Chaos
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('chaos', conf_path, 'NK_CHAOS_KEY')

          if key
            Base.requesting('Chaos')
            url = "https://dns.projectdiscovery.io/dns/#{hostname}/subdomains"
            headers = { 'Authorization' => key }

            begin
              resp = http.get(url, headers: headers)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                labels = Array(json_data['subdomains']).map(&:to_s).reject(&:empty?)
                subs = labels.map { |label| "#{label}.#{hostname}" }
                Base.found('Chaos', subs.length)
                found.concat(subs)
              else
                Base.status_error('Chaos', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[chaos_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('Chaos', e)
              Log.write("[chaos_subs] Exception = #{e}")
            end
          else
            Base.skipping('Chaos', 'API key not found!')
            Log.write('[chaos_subs] API key not found')
          end

          Log.write('[chaos_subs] Completed')
        end
      end
    end
  end
end
