# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module AnubisDB
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}AnubisDB#{Base::W}")
          url = "https://jldc.me/anubis/subdomains/#{hostname}"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            case status
            when 200
              json_out = JSON.parse(Base.safe_body(resp))
              found.concat(json_out)
              puts("#{Base::G}[+] #{Base::Y}AnubisDB #{Base::W}found #{Base::C}#{json_out.length} #{Base::W}subdomains!")
            when 204, 404, 300
              puts("#{Base::G}[+] #{Base::Y}AnubisDB #{Base::W}found #{Base::C}0 #{Base::W}subdomains!")
              Log.write("[anubis_subs] Status = #{status}, no subdomains found")
            else
              Base.print_status('AnubisDB', resp)
              Log.write("[anubis_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => e
            puts("#{Base::R}[-] #{Base::C}AnubisDB Exception : #{Base::W}#{e}")
            Log.write("[anubis_subs] Exception = #{e}")
          end

          Log.write('[anubis_subs] Completed')
        end
      end
    end
  end
end
