# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::FacebookCT implementation
      module FacebookCT
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          fb_key = Base.ensure_key('facebook', conf_path, 'NK_FB_KEY')
          return missing_facebook_key unless fb_key

          Base.requesting('Facebook')
          process_facebook_response(hostname, fb_key, http, found)
          Log.write('[fb_subs] Completed')
        end

        def missing_facebook_key
          Base.skipping('Facebook', 'API key not found!')
          Log.write('[fb_subs] API key not found')
        end

        def process_facebook_response(hostname, fb_key, http, found)
          resp = http.get('https://graph.facebook.com/certificates', params: facebook_params(hostname, fb_key))
          status = Base.safe_status(resp)
          return append_facebook_subdomains(resp, found) if status == 200

          Base.status_error('Facebook', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[fb_subs] Status = #{status}, expected 200")
        rescue StandardError => e
          Base.exception('Facebook', e)
          Log.write("[fb_subs] Exception = #{e}")
        end

        def facebook_params(hostname, fb_key)
          { query: hostname, fields: 'domains', access_token: fb_key }
        end

        def append_facebook_subdomains(resp, found)
          domains = JSON.parse(Base.safe_body(resp))['data'] || []
          Base.found('Facebook', domains.length)
          domains.each { |entry| found.concat(entry['domains'] || []) }
        end
      end
    end
  end
end
