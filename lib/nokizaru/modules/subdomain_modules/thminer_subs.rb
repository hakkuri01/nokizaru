# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module ThreatMiner
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}ThreatMiner#{Base::W}")
          url = 'https://api.threatminer.org/v2/domain.php'
          params = { q: hostname, rt: '5' }
          begin
            resp = http.get(url, params: params)
            status = Base.safe_status(resp)
            if status == 200
              json_out = JSON.parse(Base.safe_body(resp))
              subd = json_out['results'] || []
              puts("#{Base::G}[+] #{Base::Y}ThreatMiner #{Base::W}found #{Base::C}#{subd.length} #{Base::W}subdomains!")
              found.concat(subd)
            else
              Base.print_status('ThreatMiner', resp)
              Log.write("[thminer_subs] Status = #{status}, expected 200")
            end
          rescue StandardError => e
            puts("#{Base::R}[-] #{Base::C}ThreatMiner Exception : #{Base::W}#{e}")
            Log.write("[thminer_subs] Exception = #{e}")
          end
          Log.write('[thminer_subs] Completed')
        end
      end
    end
  end
end
