# frozen_string_literal: true

require 'nokogiri'
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
          status = fetch_page_status(scan_target, request_headers: request_headers)
          record_main_fetch!(result, status)
          if status[:ok]
            return page_hash(status[:effective_url] || scan_target, status[:response], status[:request_headers])
          end

          fail_crawl(result, ctx, status)
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

        def fetch_page_status(target, _redirects = nil, request_headers: {})
          current = Nokizaru::TargetIntel.normalize_http_url(target)
          return failure_status('Unsafe or malformed target URL', 'invalid_target') unless current

          state = main_fetch_state(current, request_headers)
          loop do
            step = main_fetch_step(current, target, state)
            return step unless step[:next_url]

            current = apply_main_redirect!(current, step[:next_url], state)
          end
        end

        def main_fetch_step(current, target, state)
          fetch = main_http_get(current, request_headers: state[:headers], user_agent: state[:user_agent])
          return main_fetch_error(fetch).merge(fetch_state_payload(state, current)) unless fetch[:response]

          response = fetch[:response]
          record_fetch_response!(state, response, current)
          return main_success(response, state, current) if http_success?(response)
          return activate_fallback!(state) if state[:phase] == :primary && bot_block_status?(response)
          return stopped_main_fetch(response, state, current) unless redirect_response?(response)

          redirect = next_main_redirect(current, response, target, state)
          redirect[:next_url] ? redirect : redirect.merge(fetch_state_payload(state, current))
        end

        def main_fetch_state(target, request_headers)
          {
            phase: :primary, user_agent: Crawler::USER_AGENT, headers: request_headers,
            visited: Set.new([target]), profiles: { primary: fetch_profile(target), fallback: nil }, degraded: false
          }
        end

        def fetch_profile(url)
          { status: nil, location: nil, hops: 0, effective_url: url }
        end

        def record_fetch_response!(state, response, current)
          profile = state[:profiles][state[:phase]]
          profile[:status] = Nokizaru::HTTPClient.status_code(response)
          location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
          profile[:location] = location unless location.empty?
          profile[:effective_url] = current
        end

        def activate_fallback!(state)
          state[:phase] = :fallback
          state[:user_agent] = Crawler::FALLBACK_USER_AGENT
          state[:profiles][:fallback] = fetch_profile(state[:profiles][:primary][:effective_url])
          state[:degraded] = true
          { next_url: state[:profiles][:primary][:effective_url] }
        end

        def apply_main_redirect!(current, next_url, state)
          state[:headers] = {} unless Nokizaru::TargetIntel.same_origin?(current, next_url)
          state[:visited] << next_url
          state[:profiles][state[:phase]][:hops] += 1 unless current == next_url
          next_url
        end

        def next_main_redirect(current, response, scope_url, state)
          status = Nokizaru::HTTPClient.status_code(response)
          location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
          return redirect_failure('missing_location', status) if location.empty?

          decision = Nokizaru::TargetIntel.redirect_target(current, location, scope_url: scope_url)
          reason = decision[:stop_reason]
          return redirect_failure(reason, status, canonical_handoff: decision[:canonical_handoff]) if reason

          next_url = decision[:next_url]
          return redirect_failure('loop', status, outcome: 'degraded') if state[:visited].include?(next_url)
          if total_redirect_hops(state) >= Crawler::MAX_MAIN_REDIRECTS
            return redirect_failure('max_redirects', status, outcome: 'degraded')
          end

          { next_url: next_url }
        end

        def total_redirect_hops(state)
          state[:profiles].values.compact.sum { |profile| profile[:hops] }
        end

        def main_success(response, state, current)
          Log.write("[crawler] Fallback user-agent succeeded for #{current}") if state[:phase] == :fallback
          {
            ok: true, response: response, request_headers: state[:headers], effective_url: current,
            outcome: state[:degraded] ? 'degraded' : 'ok'
          }.merge(fetch_state_payload(state, current))
        end

        def stopped_main_fetch(response, state, current)
          status = Nokizaru::HTTPClient.status_code(response)
          degraded = Crawler::BOT_BLOCK_CODES.include?(status)
          reason = 'http_status'
          reason = 'refused' if degraded
          reason = 'rate_limited' if status == 429
          outcome = degraded ? 'degraded' : 'failed'
          failure_status("HTTP status #{status}", reason, http_status: status, outcome: outcome)
            .merge(fetch_state_payload(state, current))
        end

        def fetch_state_payload(state, current)
          {
            fetch: state[:profiles], effective_url: current, active_user_agent: state[:user_agent]
          }
        end

        def record_main_fetch!(result, status)
          result['status'] = status[:outcome] || (status[:ok] ? 'ok' : 'failed')
          result['fetch'] = status[:fetch]&.to_h do |name, profile|
            [name.to_s, profile&.transform_keys(&:to_s)]
          end
          result['active_user_agent'] = status[:active_user_agent]
          result['canonical_handoff'] = status[:canonical_handoff] if status[:canonical_handoff]
        end

        def main_fetch_error(fetch)
          error = fetch[:error]
          reason = fetch[:transport] ? 'transport_error' : 'request_error'
          message = diagnostic_message(['Failed to fetch target', error&.message].compact.join(': '))
          failure_status(message, reason, error_class: error&.class&.name)
        end

        def redirect_failure(reason, http_status, canonical_handoff: nil, outcome: nil)
          reason = reason.to_s
          degraded = %w[canonical_handoff loop max_redirects].include?(reason)
          outcome ||= degraded ? 'degraded' : 'failed'
          failure = failure_status(
            "Redirect stopped: #{reason.tr('_', ' ')}", "redirect_#{reason}",
            http_status: http_status, outcome: outcome
          )
          failure.merge(canonical_handoff: canonical_handoff).compact
        end

        def failure_status(message, reason, http_status: nil, error_class: nil, outcome: 'failed')
          { fail: true, message: diagnostic_message(message), failure_reason: reason,
            http_status: http_status, error_class: error_class, outcome: outcome }
        end

        def diagnostic_message(message)
          message.to_s.gsub(/[\r\n]+/, ' ').strip[0, 500]
        end

        def bot_block_status?(response)
          Crawler::BOT_BLOCK_CODES.include?(Nokizaru::HTTPClient.status_code(response))
        rescue StandardError
          false
        end

        def page_hash(url, response, request_headers)
          { soup: Nokogiri::HTML(Nokizaru::HTTPClient.response_body(response)), url: url, request_headers: request_headers }
        end

        def fail_crawl(result, ctx, failure)
          detail = "#{failure[:message]} (#{failure[:failure_reason]})"
          UI.line(:error, detail)
          Log.write("[crawler] #{detail}")
          persist_crawl_failure!(result, ctx, failure)
          nil
        end

        def crawl_exception(result, ctx, error)
          failure = failure_status(error.to_s, 'request_error', error_class: error.class.name)
          UI.line(:error, "Exception : #{failure[:message]} (#{failure[:failure_reason]})")
          Log.write("[crawler] Exception = #{failure[:message]} (#{failure[:failure_reason]})")
          persist_crawl_failure!(result, ctx, failure)
          nil
        end

        def persist_crawl_failure!(result, ctx, failure)
          result.delete('__control__')
          result['status'] = failure[:outcome] || 'failed'
          result['error'] = failure[:message]
          %i[failure_reason http_status error_class].each do |key|
            result[key.to_s] = failure[key] if failure[key]
          end
          ctx.run['modules']['crawler'] = result
        end

        def http_get(url, request_headers: {}, user_agent: Crawler::USER_AGENT)
          with_http_retries(url) { perform_http_get(url, request_headers: request_headers, user_agent: user_agent) }
        end

        def main_http_get(url, request_headers: {}, user_agent: Crawler::USER_AGENT)
          error = nil
          response = with_http_retries(url, on_error: ->(caught) { error = caught }) do
            perform_http_request(url, request_headers: request_headers, user_agent: user_agent)
          end
          transport = Nokizaru::HTTPClient.error_response?(response)
          error = response.error if transport && response.respond_to?(:error)
          no_response = response.nil? && error.nil?
          { response: transport ? nil : response, error: error, transport: transport || no_response }
        end

        def fetch_following_same_scope_redirects(url, request_headers: {}, user_agent: Crawler::USER_AGENT,
                                                 max_redirects: Crawler::MAX_MAIN_REDIRECTS)
          current_url = Nokizaru::TargetIntel.normalize_http_url(url)
          return fetch_result(nil, url, 0, :invalid_url) unless current_url

          scope_url = current_url
          redirects = 0
          visited = Set.new([current_url])

          loop do
            response = http_get(current_url, request_headers: request_headers, user_agent: user_agent)
            return fetch_result(response, current_url, redirects, :request_failed) unless response
            return fetch_result(response, current_url, redirects, nil) unless redirect_response?(response)

            redirect = resource_redirect_step(response, current_url, scope_url, visited, redirects, max_redirects)
            return fetch_result(response, current_url, redirects, redirect[:stop_reason]) if redirect[:stop_reason]

            next_url = redirect[:next_url]
            request_headers = {} unless Nokizaru::TargetIntel.same_origin?(current_url, next_url)
            visited << next_url
            current_url = next_url
            redirects += 1
          end
        rescue StandardError => e
          Log.write("[crawler] Redirect-follow fetch error for #{url}: #{e.message}")
          fetch_result(nil, current_url, redirects, :exception)
        end

        def resource_redirect_step(response, current_url, scope_url, visited, redirects, max_redirects)
          location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
          return { stop_reason: :missing_location } if location.empty?

          decision = Nokizaru::TargetIntel.redirect_target(current_url, location, scope_url: scope_url)
          return decision if decision[:stop_reason]
          return { stop_reason: :redirect_loop } if visited.include?(decision[:next_url])
          return { stop_reason: :max_redirects } if redirects >= max_redirects

          decision
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
          response = perform_http_request(url, request_headers: request_headers, user_agent: user_agent)
          Nokizaru::HTTPClient.error_response?(response) ? nil : response
        end

        def perform_http_request(url, request_headers:, user_agent:)
          client = Nokizaru::HTTPClient.for_host(
            url,
            timeout_s: Crawler::TIMEOUT,
            follow_redirects: false,
            verify_ssl: false
          )
          client.get(url, headers: build_headers(request_headers, user_agent: user_agent))
        end

        def with_http_retries(url, on_error: nil)
          max_attempts = Crawler::MAX_HTTP_RETRIES + 1
          (1..max_attempts).each do |attempt|
            response = yield
            return response unless retryable_http_status?(response)
            return response if attempt == max_attempts

            sleep(0.15 * attempt)
          rescue StandardError => e
            Log.write("[crawler] HTTP error for #{url}: #{e.message}")
            on_error&.call(e)
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
