# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Target and option parsing helpers for runner lifecycle
      module Parsing
        private

        def validated_target!
          target = @opts[:url].to_s
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

          normalized = target.chomp('/')
          UI.row(:info, 'Target', normalized)
          normalized
        end

        def parse_target(target)
          uri = URI.parse(target)
          hostname = parse_hostname!(uri)
          protocol = uri.scheme.to_s
          ip, type_ip = resolve_target_ip(hostname)
          base_info = target_base_info(uri, protocol, hostname, ip, type_ip)
          base_info.merge(parse_runtime_options)
        end

        def target_base_info(uri, protocol, hostname, ip, type_ip)
          domain, suffix = extract_domain_parts(hostname)
          build_target_base_info(uri, protocol, hostname).merge(
            domain: domain,
            suffix: suffix,
            ip: ip,
            type_ip: type_ip,
            private_ip: IPAddr.new(ip).private?
          )
        end

        def build_target_base_info(uri, protocol, hostname)
          {
            protocol: protocol,
            hostname: hostname,
            netloc: resolve_netloc(uri, protocol, hostname),
            conf_path: "#{Paths.config_dir}/"
          }
        end

        def parse_hostname!(uri)
          hostname = uri.host.to_s
          return hostname unless hostname.empty?

          UI.line(:error, 'Unable to parse hostname from target')
          exit(1)
        end

        def resolve_target_ip(hostname)
          return [hostname, true] if ip_literal?(hostname)

          ip = resolve_hostname_ip(hostname)
          UI.row(:info, 'IP Address', ip)
          [ip, false]
        end

        def parse_runtime_options
          base_runtime_options.merge(directory_runtime_options)
        end

        def base_runtime_options
          timeout_and_dns_options.merge(scan_thread_options).merge(wordlist_option)
        end

        def timeout_and_dns_options
          {
            timeout: (@opts[:T] || Settings.timeout).to_f,
            dns_servers: (@opts[:d] || Settings.custom_dns).to_s,
            ssl_port: Integer(@opts[:sp] || Settings.ssl_port)
          }
        end

        def scan_thread_options
          {
            pscan_threads: Integer(@opts[:pt] || Settings.port_scan_threads),
            dir_threads: Integer(@opts[:dt] || Settings.dir_enum_threads)
          }
        end

        def wordlist_option
          { wordlist: (@opts[:w] || Settings.dir_enum_wordlist).to_s }
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
      end
    end
  end
end
