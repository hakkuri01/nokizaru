# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module UrlScan
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('UrlScan')

          url = "https://urlscan.io/api/v1/search/?q=domain:#{hostname}"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            if status == 200
              json_data = JSON.parse(Base.safe_body(resp))
              results = json_data['results'] || []
              subs = results.filter_map { |e| e.dig('task', 'domain') }.uniq
              found.concat(subs)
              Base.found('UrlScan', subs.length)
            else
              Base.print_status('UrlScan', resp)
              Log.write("[urlscan_subs] Status = #{status.inspect}, expected 200")
            end
          rescue StandardError => e
            Base.exception('UrlScan', e)
            Log.write("[urlscan_subs] Exception = #{e}")
          end

          Log.write('[urlscan_subs] Completed')
        end
      end
    end
  end
end
