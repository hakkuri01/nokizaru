# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::AnubisDB implementation
      module AnubisDB
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('AnubisDB')
          process_anubis_response(hostname, http, found)
          Log.write('[anubis_subs] Completed')
        end

        def process_anubis_response(hostname, http, found)
          resp = http.get("https://jldc.me/anubis/subdomains/#{hostname}")
          status = Base.safe_status(resp)
          return append_anubis_subdomains(resp, found) if status == 200
          return handle_anubis_empty(status) if [204, 404, 300].include?(status)

          Base.print_status('AnubisDB', resp)
          Log.write("[anubis_subs] Status = #{status.inspect}, expected 200")
        rescue StandardError => e
          Base.exception('AnubisDB', e)
          Log.write("[anubis_subs] Exception = #{e}")
        end

        def append_anubis_subdomains(resp, found)
          json_out = JSON.parse(Base.safe_body(resp))
          found.concat(json_out)
          Base.found('AnubisDB', json_out.length)
        end

        def handle_anubis_empty(status)
          Base.found('AnubisDB', 0)
          Log.write("[anubis_subs] Status = #{status}, no subdomains found")
        end
      end
    end
  end
end
