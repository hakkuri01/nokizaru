# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module BinaryEdge
        module_function

        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('binedge', conf_path, 'NK_BINEDGE_KEY')
          if key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}BinaryEdge#{Base::W}")
            url = "https://api.binaryedge.io/v2/query/domains/subdomain/#{hostname}"
            header = { 'X-key' => key }
            begin
              resp = http.get(url, headers: header)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                subs = json_data['events'] || []
                puts("#{Base::G}[+] #{Base::Y}binedge #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
                found.concat(subs)
              else
                puts("#{Base::R}[-] #{Base::C}binedge Status : #{Base::W}#{Base.status_label(resp)}#{Base.failure_reason(resp).empty? ? '' : " (#{Base.failure_reason(resp)})"}")
                Log.write("[binedge_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              puts("#{Base::R}[-] #{Base::C}binedge Exception : #{Base::W}#{e}")
              Log.write("[binedge_subs] Exception = #{e}")
            end
          else
            puts("#{Base::Y}[!] Skipping binedge : #{Base::W}API key not found!")
            Log.write('[binedge_subs] API key not found')
          end
          Log.write('[binedge_subs] Completed')
        end
      end
    end
  end
end
