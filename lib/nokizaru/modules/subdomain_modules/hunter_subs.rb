# frozen_string_literal: true

require 'json'
require 'base64'
require 'date'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's hunter_subs.py
      module Hunter
        module_function

        def call(hostname, conf_path, http, found)
          hunter_key = Base.ensure_key('hunter', conf_path, 'NK_HUNTER_KEY')

          if hunter_key
            puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}Hunter#{Base::W}")

            url = 'https://api.hunter.how/search'
            query = "domain.suffix==\"#{hostname}\""
            query64 = Base64.strict_encode64(query)

            start_date = Date.today.prev_year.strftime('%Y-%m-%d')
            end_date = (Date.today - 2).strftime('%Y-%m-%d')

            payload = {
              'api-key' => hunter_key,
              'query' => query64,
              'page' => 1,
              'page_size' => 1000,
              'start_time' => start_date,
              'end_time' => end_date
            }

            begin
              resp = http.get(url, params: payload)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                resp_code = json_data['code']
                if resp_code != 200
                  resp_msg = json_data['message']
                  puts("#{Base::R}[-] #{Base::C}Hunter Status : #{Base::W}#{resp_code}, #{resp_msg}")
                  Log.write("[hunter_subs] Status = #{resp_code}, expected 200")
                  return
                end

                list = json_data.dig('data', 'list') || []
                subs = list.map { |e| e['domain'] }.compact
                found.concat(subs)
                puts("#{Base::G}[+] #{Base::Y}Hunter #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
              else
                puts("#{Base::R}[-] #{Base::C}Hunter Status : #{Base::W}#{Base.status_label(resp)}#{(Base.failure_reason(resp).empty? ? "" : " (#{Base.failure_reason(resp)})")}")
                Log.write("[hunter_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => exc
              puts("#{Base::R}[-] #{Base::C}Hunter Exception : #{Base::W}#{exc}")
              Log.write("[hunter_subs] Exception = #{exc}")
            end
          else
            puts("#{Base::Y}[!] Skipping Hunter : #{Base::W}API key not found!")
            Log.write('[hunter_subs] API key not found')
          end

          Log.write('[hunter_subs] Completed')
        end
      end
    end
  end
end
