# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::UrlScan implementation
      module UrlScan
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('UrlScan')
          process_urlscan_response(hostname, http, found)
          Log.write('[urlscan_subs] Completed')
        end

        def process_urlscan_response(hostname, http, found)
          resp = http.get("https://urlscan.io/api/v1/search/?q=domain:#{hostname}")
          status = Base.safe_status(resp)
          return append_urlscan_subdomains(resp, found) if status == 200

          Base.print_status('UrlScan', resp)
          Log.write("[urlscan_subs] Status = #{status.inspect}, expected 200")
        rescue StandardError => e
          Base.exception('UrlScan', e)
          Log.write("[urlscan_subs] Exception = #{e}")
        end

        def append_urlscan_subdomains(resp, found)
          results = JSON.parse(Base.safe_body(resp))['results'] || []
          subs = results.filter_map { |entry| entry.dig('task', 'domain') }.uniq
          found.concat(subs)
          Base.found('UrlScan', subs.length)
        end
      end
    end
  end
end
