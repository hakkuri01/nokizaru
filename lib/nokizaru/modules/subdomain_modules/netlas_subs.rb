# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's netlas_subs.py
      module Netlas
        module_function

        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('netlas', conf_path, 'NK_NETLAS_KEY')

          if key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}Netlas#{Base::W}")
            url = 'https://app.netlas.io/api/domains/download/'
            headers = { 'X-API-Key' => key, 'Content-Type' => 'application/json' }
            payload = {
              q: "domain: *.#{hostname}",
              fields: ['domain'],
              source_type: 'include',
              size: '200'
            }

            begin
              resp = http.post(url, headers: headers, body: JSON.generate(payload))
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                subs = []
                json_data.each do |entry|
                  sub = entry.dig('data', 'domain')
                  subs << sub if sub
                end
                puts("#{Base::G}[+] #{Base::Y}netlas #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
                found.concat(subs)
              else
                puts("#{Base::R}[-] #{Base::C}netlas Status : #{Base::W}#{Base.status_label(resp)}#{(Base.failure_reason(resp).empty? ? "" : " (#{Base.failure_reason(resp)})")}")
                Log.write("[netlas_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => exc
              puts("#{Base::R}[-] #{Base::C}netlas Exception : #{Base::W}#{exc}")
              Log.write("[netlas_subs] Exception = #{exc}")
            end
          else
            puts("#{Base::Y}[!] Skipping netlas : #{Base::W}API key not found!")
            Log.write('[netlas_subs] API key not found')
          end

          Log.write('[netlas_subs] Completed')
        end
      end
    end
  end
end
