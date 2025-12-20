# frozen_string_literal: true

require 'json'
require_relative '../http_client'

require 'date'
require 'uri'
require_relative 'export'
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

      def safe_status(resp)
        resp.respond_to?(:status) ? resp.status : nil
      end

      def safe_body(resp)
        return '' unless resp
        return resp.body.to_s if resp.respond_to?(:body) && resp.body

        resp.to_s.to_s
      rescue StandardError
        ''
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
      def get_with_retries(client, url, params:, attempts: 2)
        (1..attempts).each do |i|
          # Some HTTPX builds do not expose a stable per-request `verify:` option.
          # Wayback endpoints have valid TLS, so rely on client defaults here.
          resp = client.get(url, params: params)
          st = safe_status(resp)
          return resp if st && st < 500 && st != 429

          # Back off on rate-limits and transient upstream errors.
          sleep((0.6 * (2**(i - 1))) + rand * 0.25) if i < attempts
        rescue StandardError => e
          raise e if i == attempts
          sleep((0.6 * (2**(i - 1))) + rand * 0.25)
        end
      end

      def call(target, data, output, timeout_s: 10.0)
        puts("\n#{Y}[!] Starting WayBack Machine...#{W}\n\n")

        # Keep Wayback strict: upstream uses a hard 10s timeout; long waits here hurt full-scan UX.
        hard_timeout = [[timeout_s.to_f, 10.0].min, 5.0].max
        client = build_http_client(hard_timeout)

        # 1) Lightweight availability hint (nice UX, but not authoritative)
        print("#{Y}[!] #{C}Checking Availability on Wayback Machine#{W}")
        $stdout.flush

        avail = false
        begin
          chk = get_with_retries(client, AVAIL_URL, params: { url: target }, attempts: 2)
          if safe_status(chk) == 200
            json = JSON.parse(safe_body(chk))
            avail = !json.fetch('archived_snapshots', {}).empty?
            puts("....[ #{avail ? "#{G}Available#{W}" : "#{R}N/A#{W}"} ]")
          else
            puts("....[ #{safe_status(chk) || 'Error'} ]")
          end
        rescue StandardError => exc
          puts("....[ Error ]")
          Log.write("[wayback] availability check exception = #{exc}")
        end

        # 2) CDX query (authoritative)
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
          resp = get_with_retries(client, CDX_URL, params: params, attempts: 2)
          st = safe_status(resp)

          if st != 200
            puts("....[ #{st || 'Error'} ]")
            Log.write("[wayback] CDX status=#{st.inspect}")
            return
          end

          lines = safe_body(resp).to_s.split("\n").map(&:strip).reject(&:empty?)
          # CDX may include a header line when output=json; using plain text, so just uniq.
          urls = lines.uniq

          if urls.empty?
            puts("....[ Not Found ]")
            Log.write("[wayback] available_hint=#{avail} but CDX returned 0 rows for #{domain_query}")
            return
          end

          puts("....[ #{G}#{urls.length}#{W} ]")

          if output
            result = { 'links' => urls, 'exported' => false }
            data['module-wayback_urls'] = result
            fname = File.join(output[:directory], "wayback_urls.#{output[:format]}")
            output[:file] = fname
            Export.call(output, data)
          end
        rescue StandardError => exc
          puts("....[ Error ]")
          puts("\n#{R}[-] Exception : #{C}#{exc}#{W}")
          Log.write("[wayback] Exception = #{exc}")
        ensure
          Log.write('[wayback] Completed')
        end
      end
    end
  end
end
