# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::ZoomEye implementation
      module ZoomEye
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          key = Base.ensure_key('zoomeye', conf_path, 'NK_ZOOMEYE_KEY')
          return missing_zoomeye_key unless key

          Base.requesting('ZoomEye')
          process_zoomeye_response(hostname, key, http, found)
          Log.write('[zoomeye_subs] Completed')
        end

        def missing_zoomeye_key
          Base.skipping('zoomeye', 'API key not found!')
          Log.write('[zoomeye_subs] API key not found')
        end

        def process_zoomeye_response(hostname, key, http, found)
          headers = { 'API-KEY' => key, 'User-Agent' => 'curl' }
          resp = http.get('https://api.zoomeye.hk/domain/search', params: { q: hostname, type: '0' }, headers: headers)
          status = Base.safe_status(resp)
          return append_zoomeye_subdomains(resp, found) if status == 200

          Base.status_error('zoomeye', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[zoomeye_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('zoomeye', e)
          Log.write("[zoomeye_subs] Exception = #{e}")
        end

        def append_zoomeye_subdomains(resp, found)
          list = JSON.parse(Base.safe_body(resp))['list'] || []
          subs = list.map { |item| item['name'] }.compact
          Base.found('zoomeye', subs.length)
          found.concat(subs)
        end
      end
    end
  end
end
