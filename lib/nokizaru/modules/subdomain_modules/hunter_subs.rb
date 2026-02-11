# frozen_string_literal: true

require 'json'
require 'base64'
require 'date'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module Hunter
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          hunter_key = Base.ensure_key('hunter', conf_path, 'NK_HUNTER_KEY')

          if hunter_key
            Base.requesting('Hunter')

            url = 'https://api.hunter.how/search'
            query = "domain.suffix==\"#{hostname}\""
            query64 = Base64.strict_encode64(query)

            start_date = Date.today.prev_year.strftime('%Y-%m-%d')
            end_date = (Date.today - 2).strftime('%Y-%m-%d')

            payload = {
              'api-key' => hunter_key,
              'query' => query64,
              'page' => 1,
              'page_size' => 1000,
              'start_time' => start_date,
              'end_time' => end_date
            }

            begin
              resp = http.get(url, params: payload)
              status = Base.safe_status(resp)
              if status == 200
                json_data = JSON.parse(Base.safe_body(resp))
                resp_code = json_data['code']
                if resp_code != 200
                  resp_msg = json_data['message']
                  Base.status_error('Hunter', resp_code, resp_msg)
                  Log.write("[hunter_subs] Status = #{resp_code}, expected 200")
                  return
                end

                list = json_data.dig('data', 'list') || []
                subs = list.map { |e| e['domain'] }.compact
                found.concat(subs)
                Base.found('Hunter', subs.length)
              else
                Base.status_error('Hunter', Base.status_label(resp), Base.failure_reason(resp))
                Log.write("[hunter_subs] Status = #{status}, expected 200")
              end
            rescue StandardError => e
              Base.exception('Hunter', e)
              Log.write("[hunter_subs] Exception = #{e}")
            end
          else
            Base.skipping('Hunter', 'API key not found!')
            Log.write('[hunter_subs] API key not found')
          end

          Log.write('[hunter_subs] Completed')
        end
      end
    end
  end
end
