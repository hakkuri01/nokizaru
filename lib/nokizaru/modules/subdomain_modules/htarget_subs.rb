# frozen_string_literal: true

require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::HackerTarget implementation
      module HackerTarget
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('HackerTarget')
          process_hackertarget_response(hostname, http, found)
          Log.write('[htarget_subs] Completed')
        end

        def process_hackertarget_response(hostname, http, found)
          resp = http.get('https://api.hackertarget.com/hostsearch/', params: { q: hostname })
          status = Base.safe_status(resp)
          return append_hackertarget_subdomains(resp, found) if status == 200

          Base.print_status('HackerTarget', resp)
          Log.write("[htarget_subs] Status = #{status.inspect}, expected 200")
        rescue StandardError => e
          Base.exception('HackerTarget', e)
          Log.write("[htarget_subs] Exception = #{e}")
        end

        def append_hackertarget_subdomains(resp, found)
          data = Base.safe_body(resp)
          subs = data.to_s.split("\n").map { |line| line.split(',', 2)[0] }.compact
          Base.found('HackerTarget', subs.length)
          found.concat(subs)
        end
      end
    end
  end
end
