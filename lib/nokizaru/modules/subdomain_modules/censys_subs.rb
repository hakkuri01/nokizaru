# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module Censys
        module_function

        MAX_PAGES = 3
        PER_PAGE = 100

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          api_id = Base.ensure_key('censys_api_id', conf_path, 'NK_CENSYS_API_ID')
          api_secret = Base.ensure_key('censys_api_secret', conf_path, 'NK_CENSYS_API_SECRET')

          if api_id && api_secret
            Base.requesting('Censys')

            begin
              subs = fetch_all_subdomains(hostname, http, api_id, api_secret)
              Base.found('Censys', subs.length)
              found.concat(subs)
            rescue StandardError => e
              Base.exception('Censys', e)
              Log.write("[censys_subs] Exception = #{e}")
            end
          else
            Base.skipping('Censys', 'API credentials not found!')
            Log.write('[censys_subs] API credentials not found')
          end

          Log.write('[censys_subs] Completed')
        end

        # Paginate provider responses and merge subdomains across result pages
        def fetch_all_subdomains(hostname, http, api_id, api_secret)
          query = "names: #{hostname}"
          cursor = nil
          page = 0
          out = []

          while page < MAX_PAGES
            resp = search_page(query, cursor, http, api_id, api_secret)
            status = Base.safe_status(resp)

            unless status == 200
              Base.status_error('Censys', Base.status_label(resp), Base.failure_reason(resp))
              Log.write("[censys_subs] Status = #{status}, expected 200")
              break
            end

            data = JSON.parse(Base.safe_body(resp))
            out.concat(extract_subdomains(hostname, data))

            cursor = data.dig('result', 'links', 'next').to_s.strip
            break if cursor.empty?

            page += 1
          end

          out.uniq
        end

        # Request one provider page using authenticated search payload settings
        def search_page(query, cursor, http, api_id, api_secret)
          url = 'https://search.censys.io/api/v2/certificates/search'
          headers = {
            'Authorization' => "Basic #{pack_basic_auth(api_id, api_secret)}",
            'Content-Type' => 'application/json'
          }
          payload = {
            q: query,
            per_page: PER_PAGE,
            cursor: cursor
          }

          http.post(url, headers: headers, body: JSON.generate(payload))
        end

        # Encode API credentials for provider basic authentication headers
        def pack_basic_auth(api_id, api_secret)
          ["#{api_id}:#{api_secret}"].pack('m0')
        end

        # Extract and normalize hostnames from provider records for this target
        def extract_subdomains(hostname, data)
          hits = Array(data.dig('result', 'hits'))
          return [] if hits.empty?

          names = hits.flat_map { |hit| Array(hit['names']) }
          names.map(&:to_s)
               .map(&:downcase)
               .select { |name| name.end_with?(hostname.downcase) }
               .reject(&:empty?)
               .uniq
        end
      end
    end
  end
end
