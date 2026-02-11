# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module AnubisDB
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('AnubisDB')
          url = "https://jldc.me/anubis/subdomains/#{hostname}"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            case status
            when 200
              json_out = JSON.parse(Base.safe_body(resp))
              found.concat(json_out)
              Base.found('AnubisDB', json_out.length)
            when 204, 404, 300
              Base.found('AnubisDB', 0)
              Log.write("[anubis_subs] Status = #{status}, no subdomains found")
            else
              Base.print_status('AnubisDB', resp)
              Log.write("[anubis_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => e
            Base.exception('AnubisDB', e)
            Log.write("[anubis_subs] Exception = #{e}")
          end

          Log.write('[anubis_subs] Completed')
        end
      end
    end
  end
end
