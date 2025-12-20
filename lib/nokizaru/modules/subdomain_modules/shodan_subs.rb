# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's shodan_subs.py
      module Shodan
        module_function

        def call(hostname, conf_path, http, found)
          sho_key = Base.ensure_key('shodan', conf_path, 'NK_SHODAN_KEY')

          if sho_key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}Shodan#{Base::W}")
            url = "https://api.shodan.io/dns/domain/#{hostname}?key=#{sho_key}"
            begin
              resp = http.get(url)
              status = Base.safe_status(resp)
              if status == 200
                json_read = JSON.parse(Base.safe_body(resp))
                subs = json_read['subdomains'] || []
                tmp = subs.map { |s| "#{s}.#{hostname}" }
                puts("#{Base::G}[+] #{Base::Y}Shodan #{Base::W}found #{Base::C}#{tmp.length} #{Base::W}subdomains!")
                found.concat(tmp)
              else
                puts("#{Base::R}[-] #{Base::C}Shodan Status : #{Base::W}#{Base.status_label(resp)}#{(Base.failure_reason(resp).empty? ? "" : " (#{Base.failure_reason(resp)})")}")
                Log.write("[shodan_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => exc
              puts("#{Base::R}[-] #{Base::C}Shodan Exception : #{Base::W}#{exc}")
              Log.write("[shodan_subs] Exception = #{exc}")
            end
          else
            puts("#{Base::Y}[!] Skipping Shodan : #{Base::W}API key not found!")
            Log.write('[shodan_subs] API key not found')
          end

          Log.write('[shodan_subs] Completed')
        end
      end
    end
  end
end
