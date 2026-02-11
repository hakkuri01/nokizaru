# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module Shodan
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          sho_key = Base.ensure_key('shodan', conf_path, 'NK_SHODAN_KEY')

          if sho_key
            Base.requesting('Shodan')
            url = "https://api.shodan.io/dns/domain/#{hostname}?key=#{sho_key}"
            begin
              resp = http.get(url)
              status = Base.safe_status(resp)
              if status == 200
                json_read = JSON.parse(Base.safe_body(resp))
                subs = json_read['subdomains'] || []
                tmp = subs.map { |s| "#{s}.#{hostname}" }
                Base.found('Shodan', tmp.length)
                found.concat(tmp)
              else
                Base.status_error('Shodan', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[shodan_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('Shodan', e)
              Log.write("[shodan_subs] Exception = #{e}")
            end
          else
            Base.skipping('Shodan', 'API key not found!')
            Log.write('[shodan_subs] API key not found')
          end

          Log.write('[shodan_subs] Completed')
        end
      end
    end
  end
end
