# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Auxiliary parsing helpers
      module ParsingSupport
        private

        def resolve_netloc(uri, protocol, hostname)
          port = uri.port
          default_port = protocol == 'https' ? 443 : 80
          port && port != default_port ? "#{hostname}:#{port}" : hostname
        end

        def resolve_hostname_ip(hostname)
          addrinfos = Addrinfo.getaddrinfo(hostname, nil, :UNSPEC, :STREAM)
          record = addrinfos.find { |info| info.ip? && info.ipv4? } || addrinfos.find(&:ip?)
          raise 'no A/AAAA records' unless record

          record.ip_address
        end

        def ip_literal?(hostname)
          IPAddr.new(hostname)
          true
        rescue StandardError
          false
        end

        def extract_domain_parts(hostname)
          return ['', ''] if ip_literal?(hostname)

          parsed = PublicSuffix.parse(hostname)
          [parsed.sld.to_s, parsed.tld.to_s]
        rescue StandardError
          fallback_domain_parts(hostname)
        end

        def fallback_domain_parts(hostname)
          labels = hostname.to_s.downcase.split('.').reject(&:empty?)
          return [hostname.to_s, ''] if labels.length < 2

          [labels[0...-1].join('.'), labels[-1]]
        end
      end
    end
  end
end
