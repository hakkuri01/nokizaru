# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module VirusTotal
        module_function

        def call(hostname, conf_path, http, found)
          vt_key = Base.ensure_key('virustotal', conf_path, 'NK_VT_KEY')

          if vt_key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}VirusTotal#{Base::W}")
            url = "https://www.virustotal.com/api/v3/domains/#{hostname}/subdomains"
            headers = { 'x-apikey' => vt_key }
            begin
              resp = http.get(url, headers: headers)
              status = Base.safe_status(resp)
              if status == 200
                json_read = JSON.parse(Base.safe_body(resp))
                domains = json_read['data'] || []
                tmp = domains.map { |d| d['id'] }.compact
                puts("#{Base::G}[+] #{Base::Y}VirusTotal #{Base::W}found #{Base::C}#{tmp.length} #{Base::W}subdomains!")
                found.concat(tmp)
              else
                puts("#{Base::R}[-] #{Base::C}VirusTotal Status : #{Base::W}#{Base.status_label(resp)}#{Base.failure_reason(resp).empty? ? '' : " (#{Base.failure_reason(resp)})"}")
                Log.write("[virustotal_subs] Status = #{status}")
              end
            rescue StandardError => e
              puts("#{Base::R}[-] #{Base::C}VirusTotal Exception : #{Base::W}#{e}")
              Log.write("[virustotal_subs] Exception = #{e}")
            end
          else
            puts("#{Base::Y}[!] Skipping VirusTotal : #{Base::W}API key not found!")
            Log.write('[virustotal_subs] API key not found')
          end

          Log.write('[virustotal_subs] Completed')
        end
      end
    end
  end
end
