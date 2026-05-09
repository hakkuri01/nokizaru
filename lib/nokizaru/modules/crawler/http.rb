# frozen_string_literal: true

require 'nokogiri'
require 'uri'
require_relative '../../http_client'

module Nokizaru
  module Modules
    module Crawler
      # HTTP fetching, anchoring and redirect handling
      module Http
        private

        def crawl_main_page(target, ctx, result)
          request_headers = ctx.options[:request_headers] || {}
          anchor = resolve_anchor(target, ctx)
          scan_target = anchor[:effective_target]
          step_row(:plus, 'Re-Anchor', "#{scan_target} (#{anchor[:reason_code]})")
          result['target'] = {
            'original' => target,
            'effective' => scan_target,
            'reanchored' => anchor[:reanchor],
            'reason' => anchor[:reason],
            'reason_code' => anchor[:reason_code]
          }
          run_fetch_loop(scan_target, result, ctx, request_headers: request_headers)
        rescue StandardError => e
          crawl_exception(result, ctx, e)
        end

        def resolve_anchor(target, ctx)
          profile = ctx.run.dig('modules', 'headers', 'target_profile')
          unless profile.is_a?(Hash)
            profile = Nokizaru::TargetIntel.profile(target, verify_ssl: false,
                                                            timeout_s: Crawler::TIMEOUT,
                                                            request_headers: ctx.options[:request_headers] || {})
          end
          decision = Nokizaru::TargetIntel.reanchor_decision(target, profile)
          decision[:reason] = profile['reason'].to_s
          decision[:reason_code] ||= Nokizaru::TargetIntel.reason_code_for(profile)
          decision
        end

        def run_fetch_loop(target, result, ctx, request_headers: {})
          current = target
          redirects = 0
          loop do
            status = fetch_page_status(current, redirects, request_headers: request_headers)
            page = page_or_failure(status, current, result, ctx)
            return page unless page == :redirect

            redirects += 1
            current = status[:next_url]
          end
        end

        def page_or_failure(status, current, result, ctx)
          return page_hash(current, status[:response], status[:request_headers]) if status[:ok]
          return fail_crawl(result, ctx, status[:message], status: status[:status]) if status[:fail]

          :redirect
        end

        def fetch_page_status(current, redirects, request_headers: {})
          response = http_get(current, request_headers: request_headers)
          return { fail: true, message: 'Failed to fetch target' } unless response
          return { ok: true, response: response, request_headers: request_headers } if http_success?(response)

          fallback = fallback_page_status(current, response, request_headers)
          return fallback if fallback

          next_url = followable_redirect(current, response, redirects)
          return { next_url: next_url } if next_url

          status = Nokizaru::HTTPClient.status_code(response)
          { fail: true, message: "HTTP status #{status}", status: status }
        end

        def fallback_page_status(current, response, request_headers)
          return nil unless bot_block_status?(response)

          fallback_response = http_get(
            current,
            request_headers: request_headers,
            user_agent: Crawler::FALLBACK_USER_AGENT
          )
          return nil unless http_success?(fallback_response)

          Log.write("[crawler] Fallback user-agent succeeded for #{current}")
          { ok: true, response: fallback_response, request_headers: request_headers }
        end

        def bot_block_status?(response)
          Crawler::BOT_BLOCK_CODES.include?(Nokizaru::HTTPClient.status_code(response))
        rescue StandardError
          false
        end

        def page_hash(url, response, request_headers)
          { soup: Nokogiri::HTML(Nokizaru::HTTPClient.response_body(response)), url: url, request_headers: request_headers }
        end

        def followable_redirect(current, response, redirects)
          return nil unless redirect_response?(response)
          return nil unless redirects < Crawler::MAX_MAIN_REDIRECTS

          location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
          return nil if location.empty?

          next_url = Nokizaru::TargetIntel.resolve_location(current, location)
          same_scope_redirect?(current, next_url) ? next_url : nil
        end

        def fail_crawl(result, ctx, message, status: nil)
          status ? UI.row(:error, 'Status', status) : UI.line(:error, message)
          Log.write("[crawler] #{message}")
          result['error'] = message
          ctx.run['modules']['crawler'] = result
          nil
        end

        def crawl_exception(result, ctx, error)
          UI.line(:error, "Exception : #{error}")
          Log.write("[crawler] Exception = #{error}")
          result['error'] = error.to_s
          ctx.run['modules']['crawler'] = result
          nil
        end

        def http_get(url, request_headers: {}, user_agent: Crawler::USER_AGENT)
          with_http_retries(url) { perform_http_get(url, request_headers: request_headers, user_agent: user_agent) }
        end

        def fetch_following_same_scope_redirects(url, request_headers: {}, user_agent: Crawler::USER_AGENT,
                                                 max_redirects: Crawler::MAX_MAIN_REDIRECTS)
          current_url = url
          redirects = 0
          visited = Set.new([current_url])

          loop do
            response = http_get(current_url, request_headers: request_headers, user_agent: user_agent)
            return fetch_result(response, current_url, redirects, :request_failed) unless response
            return fetch_result(response, current_url, redirects, nil) unless redirect_response?(response)

            location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
            return fetch_result(response, current_url, redirects, :missing_location) if location.empty?
            return fetch_result(response, current_url, redirects, :max_redirects) if redirects >= max_redirects

            next_url = Nokizaru::TargetIntel.resolve_location(current_url, location)
            # Security: prevent cross-scope redirect crawling to avoid attacker-controlled pivot expansion
            return fetch_result(response, current_url, redirects, :cross_scope) unless same_scope_redirect?(current_url,
                                                                                                            next_url)
            return fetch_result(response, current_url, redirects, :redirect_loop) if visited.include?(next_url)

            visited << next_url
            current_url = next_url
            redirects += 1
          end
        rescue StandardError => e
          Log.write("[crawler] Redirect-follow fetch error for #{url}: #{e.message}")
          fetch_result(nil, current_url, redirects, :exception)
        end

        def fetch_result(response, effective_url, redirect_hops, stop_reason)
          {
            response: response,
            effective_url: effective_url,
            redirect_hops: redirect_hops,
            stop_reason: stop_reason
          }
        end

        def perform_http_get(url, request_headers: {}, user_agent: Crawler::USER_AGENT)
          client = Nokizaru::HTTPClient.for_host(
            url,
            timeout_s: Crawler::TIMEOUT,
            follow_redirects: false,
            verify_ssl: false
          )
          response = client.get(url, headers: build_headers(request_headers, user_agent: user_agent))
          Nokizaru::HTTPClient.error_response?(response) ? nil : response
        end

        def with_http_retries(url)
          max_attempts = Crawler::MAX_HTTP_RETRIES + 1
          (1..max_attempts).each do |attempt|
            response = yield
            return response unless retryable_http_status?(response)
            return response if attempt == max_attempts

            sleep(0.15 * attempt)
          rescue StandardError => e
            Log.write("[crawler] HTTP error for #{url}: #{e.message}")
            return nil if attempt == max_attempts

            sleep(0.15 * attempt)
          end

          nil
        end

        def retryable_http_status?(response)
          code = Nokizaru::HTTPClient.status_code(response)
          code == 429 || code >= 500
        rescue StandardError => e
          Log.write("[crawler] HTTP retry check error: #{e.message}")
          false
        end
      end
    end
  end
end
