# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's alienvault_subs.py
      module AlienVault
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}AlienVault#{Base::W}")

          url = "https://otx.alienvault.com/api/v1/indicators/domain/#{hostname}/passive_dns"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            if status == 200
              json_data = JSON.parse(Base.safe_body(resp))
              passive = json_data['passive_dns'] || []
              subs = passive.filter_map { |e| e['hostname'] }.uniq
              found.concat(subs)
              puts("#{Base::G}[+] #{Base::Y}AlienVault #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
            else
              Base.print_status('AlienVault', resp)
              Log.write("[alienvault_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => exc
            puts("#{Base::R}[-] #{Base::C}AlienVault Exception : #{Base::W}#{exc}")
            Log.write("[alienvault_subs] Exception = #{exc}")
          end

          Log.write('[alienvault_subs] Completed')
        end
      end
    end
  end
end
