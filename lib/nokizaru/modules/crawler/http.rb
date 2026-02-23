# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'openssl'
require 'uri'

module Nokizaru
  module Modules
    module Crawler
      # HTTP fetching, anchoring and redirect handling
      module Http
        private

        def crawl_main_page(target, ctx, result)
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
          run_fetch_loop(scan_target, result, ctx)
        rescue StandardError => e
          crawl_exception(result, ctx, e)
        end

        def resolve_anchor(target, ctx)
          profile = ctx.run.dig('modules', 'headers', 'target_profile')
          unless profile.is_a?(Hash)
            profile = Nokizaru::TargetIntel.profile(target, verify_ssl: false,
                                                            timeout_s: Crawler::TIMEOUT)
          end
          decision = Nokizaru::TargetIntel.reanchor_decision(target, profile)
          decision[:reason] = profile['reason'].to_s
          decision[:reason_code] ||= Nokizaru::TargetIntel.reason_code_for(profile)
          decision
        end

        def run_fetch_loop(target, result, ctx)
          current = target
          redirects = 0
          loop do
            status = fetch_page_status(current, redirects)
            page = page_or_failure(status, current, result, ctx)
            return page unless page == :redirect

            redirects += 1
            current = status[:next_url]
          end
        end

        def page_or_failure(status, current, result, ctx)
          return page_hash(current, status[:response]) if status[:ok]
          return fail_crawl(result, ctx, status[:message], status: status[:status]) if status[:fail]

          :redirect
        end

        def fetch_page_status(current, redirects)
          response = http_get(current)
          return { fail: true, message: 'Failed to fetch target' } unless response
          return { ok: true, response: response } if response.is_a?(Net::HTTPSuccess)

          next_url = followable_redirect(current, response, redirects)
          return { next_url: next_url } if next_url

          { fail: true, message: "HTTP status #{response.code}", status: response.code }
        end

        def page_hash(url, response)
          { soup: Nokogiri::HTML(response.body), url: url }
        end

        def followable_redirect(current, response, redirects)
          return nil unless redirect_response?(response)
          return nil unless redirects < Crawler::MAX_MAIN_REDIRECTS

          location = response['location'].to_s.strip
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

        def http_get(url)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = Crawler::TIMEOUT
          http.read_timeout = Crawler::TIMEOUT
          enable_ssl!(http) if uri.scheme == 'https'
          http.request(build_request(uri))
        rescue StandardError => e
          Log.write("[crawler] HTTP error for #{url}: #{e.message}")
          nil
        end
      end
    end
  end
end
