# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      # Nokizaru::Modules::SubdomainModules::Censys implementation
      module Censys
        module_function

        MAX_PAGES = 3
        PER_PAGE = 100

        # Run this module and store normalized results in the run context
        def call(hostname, conf_path, http, found)
          api_id = Base.ensure_key('censys_api_id', conf_path, 'NK_CENSYS_API_ID')
          api_secret = Base.ensure_key('censys_api_secret', conf_path, 'NK_CENSYS_API_SECRET')
          return missing_censys_credentials unless api_id && api_secret

          Base.requesting('Censys')
          fetch_and_append_subdomains(hostname, http, api_id, api_secret, found)
          Log.write('[censys_subs] Completed')
        end

        def missing_censys_credentials
          Base.skipping('Censys', 'API credentials not found!')
          Log.write('[censys_subs] API credentials not found')
        end

        def fetch_and_append_subdomains(hostname, http, api_id, api_secret, found)
          subs = fetch_all_subdomains(hostname, http, api_id, api_secret)
          Base.found('Censys', subs.length)
          found.concat(subs)
        rescue StandardError => e
          Base.exception('Censys', e)
          Log.write("[censys_subs] Exception = #{e}")
        end

        # Paginate provider responses and merge subdomains across result pages
        def fetch_all_subdomains(hostname, http, api_id, api_secret)
          state = { query: "names: #{hostname}", cursor: nil, page: 0, out: [] }
          crawl_censys_pages(hostname, http, api_id, api_secret, state)
          state[:out].uniq
        end

        def crawl_censys_pages(hostname, http, api_id, api_secret, state)
          while state[:page] < MAX_PAGES
            break unless process_censys_page?(hostname, http, api_id, api_secret, state)

            state[:page] += 1
          end
        end

        def process_censys_page?(hostname, http, api_id, api_secret, state)
          resp = search_page(state[:query], state[:cursor], http, api_id, api_secret)
          status = Base.safe_status(resp)
          return false unless censys_success_status?(resp, status)

          update_censys_state!(state, hostname, resp)
          state[:cursor] != ''
        end

        def update_censys_state!(state, hostname, resp)
          data = JSON.parse(Base.safe_body(resp))
          state[:out].concat(extract_subdomains(hostname, data))
          state[:cursor] = data.dig('result', 'links', 'next').to_s.strip
        end

        def censys_success_status?(resp, status)
          return true if status == 200

          Base.status_error('Censys', Base.status_label(resp), Base.failure_reason(resp))
          Log.write("[censys_subs] Status = #{status}, expected 200")
          false
        end

        # Request one provider page using authenticated search payload settings
        def search_page(query, cursor, http, api_id, api_secret)
          http.post(censys_url, headers: censys_headers(api_id, api_secret),
                                body: JSON.generate(censys_payload(query, cursor)))
        end

        def censys_url
          'https://search.censys.io/api/v2/certificates/search'
        end

        def censys_headers(api_id, api_secret)
          {
            'Authorization' => "Basic #{pack_basic_auth(api_id, api_secret)}",
            'Content-Type' => 'application/json'
          }
        end

        def censys_payload(query, cursor)
          { q: query, per_page: PER_PAGE, cursor: cursor }
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
