# frozen_string_literal: true

require 'json'
require_relative '../http_client'
require_relative '../http_result'
require 'date'
require 'uri'
require_relative '../log'
require_relative '../version'

module Nokizaru
  module Modules
    module Wayback
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      DEFAULT_UA = "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)"
      CDX_URL    = 'https://web.archive.org/cdx/search/cdx'
      AVAIL_URL  = 'https://archive.org/wayback/available'

      def host_from_target(target)
        URI(target).host || target
      rescue StandardError
        target
      end

      def build_http_client(timeout_s, verify_ssl: true)
        Nokizaru::HTTPClient.build(
          timeout_s: timeout_s,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: true,
          persistent: true,
          verify_ssl: verify_ssl
        )
      end

      # Simple retry wrapper with exponential backoff.
      # Now returns HttpResult for consistent error handling
      def get_with_retries(client, url, params:, attempts: 2)
        last_error = nil

        (1..attempts).each do |i|
          raw_resp = client.get(url, params: params)
          http_result = HttpResult.new(raw_resp)

          # Return on success or client errors (4xx), but retry on 5xx/429
          return http_result if http_result.success? && http_result.status < 500 && http_result.status != 429

          # Back off on rate-limits and transient upstream errors
          sleep((0.6 * (2**(i - 1))) + rand * 0.25) if i < attempts
          last_error = http_result
        rescue StandardError => e
          last_error = e
          raise e if i == attempts

          sleep((0.6 * (2**(i - 1))) + rand * 0.25)
        end

        # If all retries failed, return the last error result
        last_error.is_a?(HttpResult) ? last_error : HttpResult.new(OpenStruct.new(error: last_error))
      end

      def call(target, ctx, timeout_s: 10.0)
        puts("\n#{Y}[!] Starting WayBack Machine...#{W}\n\n")

        # Keep Wayback strict: long waits here hurt full-scan UX.
        hard_timeout = [[timeout_s.to_f, 10.0].min, 5.0].max
        client = build_http_client(hard_timeout)

        # Lightweight availability hint
        print("#{Y}[!] #{C}Checking Availability on Wayback Machine#{W}")
        $stdout.flush

        avail = false
        begin
          http_result = get_with_retries(client, AVAIL_URL, params: { url: target }, attempts: 2)

          if http_result.success? && http_result.status == 200
            json = JSON.parse(http_result.body)
            avail = !json.fetch('archived_snapshots', {}).empty?
            puts("....[ #{avail ? "#{G}Available#{W}" : "#{R}N/A#{W}"} ]")
          else
            status_msg = http_result.status || http_result.error_message || 'Error'
            puts("....[ #{status_msg} ]")
            Log.write("[wayback] availability check failed: #{http_result.error_message}") if http_result.error?
          end
        rescue StandardError => e
          puts('....[ Error ]')
          Log.write("[wayback] availability check exception = #{e}")
        end

        # CDX query (authoritative)
        print("#{Y}[!] #{C}Fetching URLs#{W}")
        $stdout.flush

        curr_yr = Date.today.year
        last_yr = curr_yr - 5

        host = host_from_target(target)
        domain_query = "#{host}/*"

        params = {
          url: domain_query,
          fl: 'original',
          fastLatest: 'true',
          collapse: 'urlkey',
          filter: 'statuscode:200',
          from: last_yr.to_s,
          to: curr_yr.to_s,
          limit: '25000'
        }

        begin
          cache_key = ctx.cache&.key_for(['wayback', domain_query, last_yr, curr_yr]) ||
                      "wayback:#{domain_query}:#{last_yr}:#{curr_yr}"

          urls = ctx.cache_fetch(cache_key, ttl_s: 43_200) do
            http_result = get_with_retries(client, CDX_URL, params: params, attempts: 2)

            if http_result.error?
              Log.write("[wayback] CDX request failed: #{http_result.error_message}")
              []
            elsif http_result.status != 200
              Log.write("[wayback] CDX status=#{http_result.status}")
              []
            else
              lines = http_result.body.to_s.split("\n").map(&:strip).reject(&:empty?)
              lines.uniq
            end
          end

          if urls.empty?
            puts('....[ Not Found ]')
            Log.write("[wayback] available_hint=#{avail} but CDX returned 0 rows for #{domain_query}")
            ctx.run['modules']['wayback'] = { 'urls' => [] }
            return
          end

          puts("....[ #{G}#{urls.length}#{W} ]")

          ctx.run['modules']['wayback'] = { 'urls' => urls, 'available_hint' => avail }
          ctx.add_artifact('urls', urls)
          ctx.add_artifact('wayback_urls', urls)
        rescue StandardError => e
          puts('....[ Error ]')
          puts("\n#{R}[-] Exception : #{C}#{e}#{W}")
          Log.write("[wayback] Exception = #{e}")
        ensure
          Log.write('[wayback] Completed')
        end
      end
    end
  end
end
