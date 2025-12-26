# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's crtsh_subs.py
      module CrtSh
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}crt.sh#{Base::W}")

          # Match upstream query param (slightly more reliable than ?q= on some runs).
          url = "https://crt.sh/?dNSName=%25.#{hostname}&output=json"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            if status == 200
              output = Base.safe_body(resp)
              json_out = JSON.parse(output)

              subs = []
              json_out.each do |entry|
                name = entry['name_value']
                next unless name

                name.to_s.split("\n").each { |n| subs << n.strip }
              end

              subs.reject!(&:empty?)
              subs.uniq!
              puts("#{Base::G}[+] #{Base::Y}crt.sh #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
              found.concat(subs)
            else
              Base.print_status('crt.sh', resp)
              Log.write("[crtsh_subs] Status = #{status.inspect}, expected 200")
            end
          rescue JSON::ParserError => exc
            puts("#{Base::R}[-] #{Base::C}crt.sh Exception : #{Base::W}invalid JSON (#{exc.message})")
            Log.write("[crtsh_subs] JSON parse exception = #{exc}")
          rescue StandardError => exc
            puts("#{Base::R}[-] #{Base::C}crt.sh Exception : #{Base::W}#{exc}")
            Log.write("[crtsh_subs] Exception = #{exc}")
          end

          Log.write('[crtsh_subs] Completed')
        end
      end
    end
  end
end
