# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Transliteration of FinalRecon's urlscan_subs.py
      module UrlScan
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}UrlScan#{Base::W}")

          url = "https://urlscan.io/api/v1/search/?q=domain:#{hostname}"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            if status == 200
              json_data = JSON.parse(Base.safe_body(resp))
              results = json_data['results'] || []
              subs = results.filter_map { |e| e.dig('task', 'domain') }.uniq
              found.concat(subs)
              puts("#{Base::G}[+] #{Base::Y}UrlScan #{Base::W}found #{Base::C}#{subs.length} #{Base::W}subdomains!")
            else
              Base.print_status('UrlScan', resp)
              Log.write("[urlscan_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => exc
            puts("#{Base::R}[-] #{Base::C}UrlScan Exception : #{Base::W}#{exc}")
            Log.write("[urlscan_subs] Exception = #{exc}")
          end

          Log.write('[urlscan_subs] Completed')
        end
      end
    end
  end
end
