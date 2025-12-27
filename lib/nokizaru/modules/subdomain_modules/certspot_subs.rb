# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module CertSpotter
        module_function

        def call(hostname, http, found)
          puts("#{Base::Y}[!] #{Base::C}Requesting #{Base::G}CertSpotter#{Base::W}")
          url = 'https://api.certspotter.com/v1/issuances'
          params = { domain: hostname, expand: 'dns_names', include_subdomains: 'true' }
          begin
            resp = http.get(url, params: params)
            status = Base.safe_status(resp)
            if status == 200
              json_read = JSON.parse(Base.safe_body(resp))
              puts("#{Base::G}[+] #{Base::Y}Certspotter #{Base::W}found #{Base::C}#{json_read.length} #{Base::W}subdomains!")
              json_read.each do |entry|
                found.concat(entry['dns_names'] || [])
              end
            else
              puts("#{Base::R}[-] #{Base::C}CertSpotter Status : #{Base::W}#{Base.status_label(resp)}#{Base.failure_reason(resp).empty? ? '' : " (#{Base.failure_reason(resp)})"}")
              Log.write("[certspot_subs] Status = #{status}, expected 200")
            end
          rescue StandardError => e
            puts("#{Base::R}[-] #{Base::C}CertSpotter Exception : #{Base::W}#{e}")
            Log.write("[certspot_subs] Exception = #{e}")
          end
          Log.write('[certspot_subs] Completed')
        end
      end
    end
  end
end
