# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module ZoomEye
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('zoomeye', conf_path, 'NK_ZOOMEYE_KEY')
          if key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}ZoomEye#{Base::W}")
            url = 'https://api.zoomeye.hk/domain/search'
            headers = { 'API-KEY' => key, 'User-Agent' => 'curl' }
            begin
              resp = http.get(url, params: { q: hostname, type: '0' }, headers: headers)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                list = json_data['list'] || []
                subs = list.map { |s| s['name'] }.compact
                puts("#{Base::G}[+] #{Base::Y}zoomeye #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
                found.concat(subs)
              else
                puts("#{Base::R}[-] #{Base::C}zoomeye Status : #{Base::W}#{Base.status_label(resp)}#{Base.failure_reason(resp).empty? ? '' : " (#{Base.failure_reason(resp)})"}")
                Log.write("[zoomeye_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              puts("#{Base::R}[-] #{Base::C}zoomeye Exception : #{Base::W}#{e}")
              Log.write("[zoomeye_subs] Exception = #{e}")
            end
          else
            puts("#{Base::Y}[!] Skipping zoomeye : #{Base::W}API key not found!")
            Log.write('[zoomeye_subs] API key not found')
          end
          Log.write('[zoomeye_subs] Completed')
        end
      end
    end
  end
end
