# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::CrtSh implementation
      module CrtSh
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('crt.sh')
          process_crtsh_response(hostname, http, found)
          Log.write('[crtsh_subs] Completed')
        end

        def process_crtsh_response(hostname, http, found)
          resp = http.get("https://crt.sh/?dNSName=%25.#{hostname}&output=json")
          status = Base.safe_status(resp)
          return append_crtsh_subdomains(resp, found) if status == 200

          handle_crtsh_status_error(resp, status)
        rescue JSON::ParserError => e
          Base.exception('crt.sh', "invalid JSON (#{e.message})")
          Log.write("[crtsh_subs] JSON parse exception = #{e}")
        rescue StandardError => e
          Base.exception('crt.sh', e)
          Log.write("[crtsh_subs] Exception = #{e}")
        end

        def append_crtsh_subdomains(resp, found)
          subs = extract_crtsh_subdomains(JSON.parse(Base.safe_body(resp)))
          Base.found('crt.sh', subs.length)
          found.concat(subs)
        end

        def extract_crtsh_subdomains(entries)
          entries.flat_map { |entry| entry['name_value'].to_s.split("\n").map(&:strip) }
                 .reject(&:empty?)
                 .uniq
        end

        def handle_crtsh_status_error(resp, status)
          Base.print_status('crt.sh', resp)
          Log.write("[crtsh_subs] Status = #{status.inspect}, expected 200")
        end
      end
    end
  end
end
