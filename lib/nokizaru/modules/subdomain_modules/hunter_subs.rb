# frozen_string_literal: true

require 'json'
require 'base64'
require 'date'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::Hunter implementation
      module Hunter
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          hunter_key = Base.ensure_key('hunter', conf_path, 'NK_HUNTER_KEY')
          return missing_hunter_key unless hunter_key

          Base.requesting('Hunter')
          process_hunter_response(hostname, hunter_key, http, found)
          Log.write('[hunter_subs] Completed')
        end

        def missing_hunter_key
          Base.skipping('Hunter', 'API key not found!')
          Log.write('[hunter_subs] API key not found')
        end

        def process_hunter_response(hostname, hunter_key, http, found)
          resp = http.get('https://api.hunter.how/search', params: hunter_payload(hostname, hunter_key))
          status = Base.safe_status(resp)
          return handle_hunter_http_error(resp, status) unless status == 200

          append_hunter_subdomains(resp, found)
        rescue StandardError => e
          Base.exception('Hunter', e)
          Log.write("[hunter_subs] Exception = #{e}")
        end

        def hunter_payload(hostname, hunter_key)
          {
            'api-key' => hunter_key,
            'query' => Base64.strict_encode64("domain.suffix==\"#{hostname}\""),
            'page' => 1,
            'page_size' => 1000,
            'start_time' => Date.today.prev_year.strftime('%Y-%m-%d'),
            'end_time' => (Date.today - 2).strftime('%Y-%m-%d')
          }
        end

        def append_hunter_subdomains(resp, found)
          json_data = JSON.parse(Base.safe_body(resp))
          return handle_hunter_api_error(json_data) unless json_data['code'] == 200

          subs = Array(json_data.dig('data', 'list')).map { |entry| entry['domain'] }.compact
          found.concat(subs)
          Base.found('Hunter', subs.length)
        end

        def handle_hunter_http_error(resp, status)
          Base.status_error('Hunter', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[hunter_subs] Status = #{status}, expected 200")
        end

        def handle_hunter_api_error(json_data)
          code = json_data['code']
          Base.status_error('Hunter', code, json_data['message'])
          Log.write("[hunter_subs] Status = #{code}, expected 200")
        end
      end
    end
  end
end
