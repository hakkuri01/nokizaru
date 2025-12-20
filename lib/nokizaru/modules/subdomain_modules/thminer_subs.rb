# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's thminer_subs.py
      module ThreatMiner
        module_function

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
          rescue StandardError => exc
            puts("#{Base::R}[-] #{Base::C}ThreatMiner Exception : #{Base::W}#{exc}")
            Log.write("[thminer_subs] Exception = #{exc}")
          end
          Log.write('[thminer_subs] Completed')
        end
      end
    end
  end
end
