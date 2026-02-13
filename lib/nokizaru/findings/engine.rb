# frozen_string_literal: true

require 'time'

module Nokizaru
  module Findings
    class Engine
      DEFAULT_DAYS_TO_EXPIRY_WARN = 14

      # Coordinate the end to end scan workflow from setup to final output
      def run(run)
        findings = []
        modules = run.fetch('modules', {})

        findings.concat(headers_findings(modules['headers']))
        findings.concat(tls_findings(modules['sslinfo']))
        findings.concat(dns_findings(modules['dns']))
        findings.concat(port_findings(modules['portscan']))
        findings.concat(dir_findings(modules['directory_enum']))

        # Normalize
        findings = findings.compact
        findings.each_with_index do |f, idx|
          f['id'] ||= "finding.#{idx}"
          f['severity'] ||= 'low'
        end

        findings
      end

      private

      # Generate findings from security header gaps and risky values
      def headers_findings(h)
        return [] unless h.is_a?(Hash)

        headers = (h['headers'] || h).transform_keys { |k| k.to_s.downcase }

        res = []
        security = {
          'strict-transport-security' => ['medium', 'HSTS header missing',
                                          'Enable Strict-Transport-Security if the site is HTTPS-only.'],
          'content-security-policy' => ['medium', 'CSP header missing',
                                        'Add a Content-Security-Policy to reduce XSS risk.'],
          'x-content-type-options' => ['low', 'X-Content-Type-Options header missing',
                                       'Set X-Content-Type-Options: nosniff.'],
          'x-frame-options' => ['low', 'X-Frame-Options header missing',
                                'Set X-Frame-Options to mitigate clickjacking.'],
          'referrer-policy' => ['low', 'Referrer-Policy header missing',
                                'Set Referrer-Policy to reduce referrer leakage.']
        }

        security.each do |key, (sev, title, rec)|
          next if headers.key?(key)

          res << {
            'id' => "headers.missing_#{key.gsub(/[^a-z0-9]+/, '_')}",
            'severity' => sev,
            'title' => title,
            'evidence' => "Response did not include #{key}",
            'recommendation' => rec,
            'module' => 'headers',
            'tags' => %w[headers posture]
          }
        end

        # Cookie flags
        set_cookie = headers['set-cookie']
        if set_cookie
          cookies = Array(set_cookie.is_a?(Array) ? set_cookie : set_cookie.to_s.split(/\n|,(?=\s*\w+=)/))
          cookies.each do |c|
            next if c.to_s.strip.empty?

            missing = []
            missing << 'Secure' unless c.downcase.include?('secure')
            missing << 'HttpOnly' unless c.downcase.include?('httponly')
            missing << 'SameSite' unless c.downcase.include?('samesite')
            next if missing.empty?

            res << {
              'id' => "cookies.missing_flags.#{c.hash}",
              'severity' => 'low',
              'title' => 'Cookie missing recommended flags',
              'evidence' => "Set-Cookie missing: #{missing.join(', ')}",
              'recommendation' => 'Add Secure, HttpOnly, and SameSite where appropriate.',
              'module' => 'headers',
              'tags' => %w[cookies headers posture]
            }
          end
        end

        res
      end

      # Generate findings from weak TLS configuration and certificate issues
      def tls_findings(ssl)
        return [] unless ssl.is_a?(Hash)

        cert = ssl['cert'] || ssl
        not_after = cert['notAfter'] || cert['not_after'] || cert['not_after_gmt']
        return [] unless not_after

        exp = begin
          Time.parse(not_after.to_s)
        rescue StandardError
          nil
        end
        return [] unless exp

        days = ((exp - Time.now) / 86_400.0).round(2)
        if days.negative?
          [{
            'id' => 'tls.cert_expired',
            'severity' => 'high',
            'title' => 'TLS certificate expired',
            'evidence' => "Certificate expired #{days.abs} days ago (#{not_after})",
            'recommendation' => 'Renew and deploy a valid certificate.',
            'module' => 'sslinfo',
            'tags' => %w[tls posture]
          }]
        elsif days <= DEFAULT_DAYS_TO_EXPIRY_WARN
          [{
            'id' => 'tls.cert_expiring',
            'severity' => 'medium',
            'title' => 'TLS certificate expiring soon',
            'evidence' => "Certificate expires in #{days} days (#{not_after})",
            'recommendation' => 'Plan certificate renewal before expiry.',
            'module' => 'sslinfo',
            'tags' => %w[tls posture]
          }]
        else
          []
        end
      end

      # Generate findings from DNS records that indicate risk or misconfiguration
      def dns_findings(dns)
        return [] unless dns.is_a?(Hash)

        txt = Array(dns.dig('records', 'TXT')) + Array(dns['txt'])
        dmarc = Array(dns.dig('records', 'DMARC')) + Array(dns['dmarc'])

        has_spf = txt.any? { |t| t.to_s.downcase.include?('v=spf1') }
        has_dmarc = dmarc.any? { |t| t.to_s.downcase.include?('v=dmarc1') }

        res = []
        unless has_spf
          res << {
            'id' => 'dns.missing_spf',
            'severity' => 'low',
            'title' => 'SPF record not detected',
            'evidence' => 'No TXT record containing v=spf1 was observed.',
            'recommendation' => 'If the domain sends email, publish an SPF policy.',
            'module' => 'dns',
            'tags' => %w[dns email posture]
          }
        end
        unless has_dmarc
          res << {
            'id' => 'dns.missing_dmarc',
            'severity' => 'low',
            'title' => 'DMARC record not detected',
            'evidence' => 'No _dmarc TXT record containing v=DMARC1 was observed.',
            'recommendation' => 'If the domain sends email, publish a DMARC policy.',
            'module' => 'dns',
            'tags' => %w[dns email posture]
          }
        end
        res
      end

      # Generate findings from exposed ports and high risk services
      def port_findings(ps)
        return [] unless ps.is_a?(Hash)

        ports = Array(ps['open_ports']).map(&:to_s)
        return [] if ports.empty?

        risky = ports.select do |p|
          p.start_with?('2375') || p.start_with?('27017') || p.start_with?('6379') || p.start_with?('9200') || p.start_with?('11211')
        end
        return [] if risky.empty?

        [{
          'id' => 'ports.sensitive_open',
          'severity' => 'medium',
          'title' => 'Potentially sensitive service ports detected',
          'evidence' => "Open ports include: #{risky.join(', ')}",
          'recommendation' => 'Validate exposure is intended; restrict access with network controls where possible.',
          'module' => 'portscan',
          'tags' => %w[ports posture]
        }]
      end

      # Generate findings from sensitive directories discovered during scans
      def dir_findings(dir)
        return [] unless dir.is_a?(Hash)

        by_status = dir['by_status'].is_a?(Hash) ? dir['by_status'] : {}
        high_signal = %w[200 204 401 403 405 500]
        found = high_signal.flat_map { |status| Array(by_status[status]) }.map(&:to_s)
        found = Array(dir['found']).map(&:to_s) if found.empty?
        return [] if found.empty?

        interesting = found.select { |u| u =~ %r{/(admin|backup|\.git|\.env|config|debug|swagger|api|graphql)\b}i }
        return [] if interesting.empty?

        [{
          'id' => 'dir.interesting_paths',
          'severity' => 'low',
          'title' => 'Interesting paths discovered',
          'evidence' => interesting.first(20).join(', ') + (interesting.length > 20 ? '…' : ''),
          'recommendation' => 'Review discovered endpoints for unintended exposure.',
          'module' => 'directory_enum',
          'tags' => %w[content discovery]
        }]
      end
    end
  end
end
