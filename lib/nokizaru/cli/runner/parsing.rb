# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      module Parsing
        private

        def validated_target!
          target = @opts[:target].to_s
          return valid_target_with_protocol(target) unless target.empty?

          UI.line(:error, 'No Target Specified!')
          exit(1)
        end

        def valid_target_with_protocol(target)
          unless target.start_with?('http://', 'https://')
            UI.line(:error, 'Protocol Missing, Include http:// or https://')
            Log.write("Protocol missing in #{target}, exiting")
            exit(1)
          end

          target.chomp('/')
        end

        def parse_target(target)
          uri = URI.parse(target)
          reject_target_credentials!(uri)
          warn_on_unusual_scheme_port(uri)
          hostname = parse_hostname!(uri)
          protocol = uri.scheme.to_s
          ip, type_ip, ip_resolution_error = resolve_target_ip(hostname)
          print_target_context(target, ip, ip_resolution_error)
          base_info = target_base_info(uri, protocol, hostname, ip, type_ip)
          base_info.merge(ip_resolution_error: ip_resolution_error).merge(parse_runtime_options)
        end

        def print_target_context(target, ip, ip_resolution_error = nil)
          ip_display = ip || "unresolved (#{ip_resolution_error})"
          UI.rows(:info, [['Target', target], ['IP Address', ip_display]])
        end

        # Security: credentials in the target URL would reach the terminal, the log, exports, and third-party
        # lookups, so they are refused in favor of -H, which is never echoed (cost acceptable: one check per run)
        def reject_target_credentials!(uri)
          return unless uri.userinfo

          UI.line(:error, "Credentials in the target URL are not supported, pass them with -H 'Authorization: …'")
          exit(1)
        end

        # Security: a query string can carry tokens, so third-party lookups (Wappalyzer, archive.org) get the URL
        # without it (cost acceptable because both look up a page or a host, not a query)
        def third_party_target(target)
          uri = URI.parse(target)
          uri.query = nil
          uri.fragment = nil
          uri.to_s
        end

        def warn_on_unusual_scheme_port(uri)
          return if uri.port.nil?
          return unless unusual_scheme_port?(uri.scheme.to_s, uri.port)

          UI.row(:info, 'Target Notice', "Using #{uri.scheme} with port #{uri.port}")
        end

        def unusual_scheme_port?(scheme, port)
          (scheme == 'http' && port.to_i == 443) || (scheme == 'https' && port.to_i == 80)
        end

        def target_base_info(uri, protocol, hostname, ip, type_ip)
          domain, suffix = extract_domain_parts(hostname)
          build_target_base_info(uri, protocol, hostname).merge(
            domain: domain,
            suffix: suffix,
            ip: ip,
            type_ip: type_ip,
            private_ip: private_ip?(ip)
          )
        end

        def build_target_base_info(uri, protocol, hostname)
          {
            protocol: protocol,
            hostname: hostname,
            netloc: resolve_netloc(uri, protocol, hostname)
          }
        end

        def parse_hostname!(uri)
          hostname = uri.host.to_s
          return hostname unless hostname.empty?

          UI.line(:error, 'Unable to parse hostname from target')
          exit(1)
        end

        def resolve_target_ip(hostname)
          return [hostname, true, nil] if ip_literal?(hostname)

          ip = resolve_hostname_ip(hostname)
          [ip, false, nil]
        rescue StandardError => e
          Log.write("Target IP resolution failed for #{hostname}: #{e.class}: #{e.message}")
          [nil, false, e.message]
        end

        def parse_runtime_options
          base_runtime_options.merge(directory_runtime_options)
        end

        def base_runtime_options
          timeout_and_dns_options.merge(scan_thread_options).merge(wordlist_option).merge(request_header_option)
        end

        def timeout_and_dns_options
          {
            timeout: positive_number(:T, Settings.timeout),
            dns_servers: (@opts[:d] || Settings.custom_dns).to_s,
            ssl_port: positive_number(:sp, Settings.ssl_port, integer: true)
          }
        end

        def scan_thread_options
          {
            pscan_threads: positive_number(:pt, Settings.port_scan_threads, integer: true),
            pscan_ports: @opts[:p],
            dir_threads: positive_number(:dt, Settings.dir_enum_threads, integer: true)
          }
        end

        # A zero or negative timeout disables every module budget and a zero pool size crashes the scan, so both
        # stop the run before it starts
        def positive_number(key, default, integer: false)
          raw = @opts[key] || default
          value = integer ? Integer(raw) : Float(raw)
          return value if value.positive?

          invalid_number!(key)
        rescue ArgumentError, TypeError
          invalid_number!(key)
        end

        def invalid_number!(key)
          UI.line(:error, "-#{key} must be a positive number")
          exit(1)
        end

        def wordlist_option
          { wordlist: @opts[:w] ? Settings.wordlist(@opts[:w]) : Settings.dir_enum_wordlist }
        end

        def request_header_option
          { request_headers: parsed_request_headers }
        end

        def parsed_request_headers
          Nokizaru::RequestHeaders.parse_argv(@argv)
        rescue ArgumentError => e
          UI.line(:error, e.message)
          exit(1)
        end

        def directory_runtime_options
          {
            allow_redirects: bool_opt(:r, Settings.dir_enum_redirect),
            verify_ssl: bool_opt(:s, Settings.dir_enum_verify_ssl),
            extensions: (@opts[:e] || Settings.dir_enum_extension).to_s
          }
        end

        def bool_opt(key, default)
          @opts[key].nil? ? default : !!@opts[key]
        end

        def private_ip?(ip)
          return false if ip.to_s.empty?

          IPAddr.new(ip).private?
        rescue StandardError
          false
        end
      end
    end
  end
end
