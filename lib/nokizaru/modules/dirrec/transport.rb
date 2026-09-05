# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Transport
        private

        def request_url(client, url, stop_state)
          return request_url_with_custom_headers(client, url, stop_state) if custom_request_headers?(stop_state)

          response = perform_client_request(client, url, stop_state)
          return response unless head_confirmation_required?(stop_state, response)

          perform_client_request(client, url, stop_state, force_method: :get)
        end

        def request_urls(client, urls, stop_state)
          return urls.map { |url| request_url(client, url, stop_state) } if manual_redirect_batch_fallback?(stop_state)

          headers = custom_request_headers?(stop_state) ? stop_state[:request_headers] : nil
          responses = perform_client_batch_request(client, urls, stop_state, headers: headers)
          confirm_head_batch!(client, urls, responses, stop_state, headers)
        end

        def manual_redirect_batch_fallback?(stop_state)
          custom_request_headers?(stop_state) && stop_state[:allow_redirects]
        end

        def custom_request_headers?(stop_state)
          Nokizaru::RequestHeaders.any?(stop_state[:request_headers])
        end

        def request_url_with_custom_headers(client, url, stop_state)
          unless stop_state[:allow_redirects]
            response = perform_client_request(client, url, stop_state,
                                              headers: stop_state[:request_headers])
            return response unless head_confirmation_required?(stop_state, response)

            return perform_client_request(client, url, stop_state, headers: stop_state[:request_headers],
                                                                   force_method: :get)
          end

          request_url_following_same_scope_redirects(client, url, stop_state)
        end

        def request_url_following_same_scope_redirects(client, url, stop_state)
          current = url
          redirects = 0

          loop do
            response = perform_client_request(client, current, stop_state, headers: stop_state[:request_headers])
            if head_confirmation_required?(stop_state, response)
              response = perform_client_request(client, current, stop_state, headers: stop_state[:request_headers],
                                                                             force_method: :get)
            end
            next_url = same_scope_redirect_url(current, response)
            return response unless next_url && redirects < Crawler::MAX_MAIN_REDIRECTS

            current = next_url
            redirects += 1
          end
        end

        def perform_client_request(client, url, stop_state, headers: nil, force_method: nil)
          method = (force_method || stop_state[:request_method]).to_s
          request_headers = headers || {}

          if method == 'head' && client.respond_to?(:head)
            client.head(url, headers: request_headers)
          else
            client.get(url, headers: request_headers)
          end
        end

        def perform_client_batch_request(client, urls, stop_state, headers: nil, force_method: nil)
          method = (force_method || stop_state[:request_method]).to_s
          request_headers = headers || {}
          responses = if method == 'head' && client.respond_to?(:head)
                        client.head(*urls, headers: request_headers)
                      else
                        client.get(*urls, headers: request_headers)
                      end
          Array(responses)
        end

        def confirm_head_batch!(client, urls, responses, stop_state, headers)
          return responses unless stop_state[:request_method].to_s == 'head'

          confirmations = head_confirmation_urls(urls, responses, stop_state)
          return responses if confirmations.empty?

          confirmed = perform_client_batch_request(
            client,
            confirmations.map(&:last),
            stop_state,
            headers: headers,
            force_method: :get
          )
          confirmations.each_with_index do |(index, _url), confirmed_index|
            responses[index] = confirmed[confirmed_index]
          end
          responses
        end

        def head_confirmation_urls(urls, responses, stop_state)
          responses.each_with_index.filter_map do |response, index|
            [index, urls[index]] if head_confirmation_required?(stop_state, response)
          end
        end

        def head_confirmation_required?(stop_state, response)
          return false unless stop_state[:request_method].to_s == 'head'
          return false unless response.respond_to?(:status)

          status = response.status.to_i
          FINDING_CANDIDATE_STATUSES.include?(status)
        end

        def same_scope_redirect_url(current_url, response)
          return nil unless response.respond_to?(:status)
          return nil unless redirect_status?(response.status)

          location = response.headers['location']
          return nil if location.to_s.strip.empty?

          next_url = Nokizaru::TargetIntel.resolve_location(current_url, location)
          Nokizaru::TargetIntel.same_scope_host?(URI.parse(current_url).host, URI.parse(next_url).host) ? next_url : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
