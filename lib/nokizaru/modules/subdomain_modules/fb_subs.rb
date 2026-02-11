# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module FacebookCT
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          fb_key = Base.ensure_key('facebook', conf_path, 'NK_FB_KEY')

          if fb_key
            Base.requesting('Facebook')
            url = 'https://graph.facebook.com/certificates'
            params = { query: hostname, fields: 'domains', access_token: fb_key }
            begin
              resp = http.get(url, params: params)
              status = Base.safe_status(resp)
              if status == 200
                json_read = JSON.parse(Base.safe_body(resp))
                domains = json_read['data'] || []
                Base.found('Facebook', domains.length)
                domains.each do |entry|
                  found.concat(entry['domains'] || [])
                end
              else
                Base.status_error('Facebook', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[fb_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('Facebook', e)
              Log.write("[fb_subs] Exception = #{e}")
            end
          else
            Base.skipping('Facebook', 'API key not found!')
            Log.write('[fb_subs] API key not found')
          end

          Log.write('[fb_subs] Completed')
        end
      end
    end
  end
end
