# frozen_string_literal: true

require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's htarget_subs.py
      module HackerTarget
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}HackerTarget#{Base::W}")
          url = "https://api.hackertarget.com/hostsearch/"

          begin
            resp = http.get(url, params: { q: hostname })
            status = Base.safe_status(resp)

            if status == 200
              data = Base.safe_body(resp)
              tmp = data.to_s.split("\n").map { |line| line.split(',', 2)[0] }.compact
              puts("#{Base::G}[+] #{Base::Y}HackerTarget #{Base::W}found #{Base::C}#{tmp.length} #{Base::W}subdomains!")
              found.concat(tmp)
            else
              Base.print_status('HackerTarget', resp)
              Log.write("[htarget_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => exc
            puts("#{Base::R}[-] #{Base::C}HackerTarget Exception : #{Base::W}#{exc}")
            Log.write("[htarget_subs] Exception = #{exc}")
          end

          Log.write('[htarget_subs] Completed')
        end
      end
    end
  end
end
