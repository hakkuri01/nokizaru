require "digest/crc32"
require "../finding"
require "../modules/headers"

module Nokizaru
  module Findings
    # Response-header posture findings: missing security headers and cookies
    # missing recommended flags. Consumes the typed Headers result. Ports
    # findings/header_rules.rb.
    module HeaderRules
      extend self

      SECURITY_HEADERS = {
        "strict-transport-security" => {"medium", "HSTS header missing",
                                        "Enable Strict-Transport-Security if the site is HTTPS-only."},
        "content-security-policy" => {"medium", "CSP header missing",
                                      "Add a Content-Security-Policy to reduce XSS risk."},
        "x-content-type-options" => {"low", "X-Content-Type-Options header missing",
                                     "Set X-Content-Type-Options: nosniff."},
        "x-frame-options" => {"low", "X-Frame-Options header missing",
                              "Set X-Frame-Options to mitigate clickjacking."},
        "referrer-policy" => {"low", "Referrer-Policy header missing",
                              "Set Referrer-Policy to reduce referrer leakage."},
      }

      # A comma begins a new cookie only when a name= follows, since Expires dates
      # hold commas; the split lives on the Headers module and is shared here.
      def call(result : Modules::Headers::Result?) : Array(Finding)
        return [] of Finding if result.nil? || !result.success?

        headers = result.headers
        missing_header_findings(headers) + cookie_flag_findings(headers["set-cookie"]?)
      end

      private def missing_header_findings(headers : Hash(String, String)) : Array(Finding)
        SECURITY_HEADERS.compact_map do |name, payload|
          next if headers.has_key?(name)

          severity, title, recommendation = payload
          Finding.new(
            id: "headers.missing_#{name.gsub(/[^a-z0-9]+/, "_")}",
            severity: severity,
            title: title,
            source_module: "headers",
            tags: ["headers", "posture"],
            evidence: "Response did not include #{name}",
            recommendation: recommendation,
          )
        end
      end

      private def cookie_flag_findings(set_cookie : String?) : Array(Finding)
        return [] of Finding if set_cookie.nil?

        split = Modules::Headers.split_set_cookie(set_cookie)
        split.compact_map do |cookie|
          missing = missing_cookie_flags(cookie)
          next if missing.empty?

          Finding.new(
            id: "cookies.missing_flags.#{Digest::CRC32.checksum(cookie_name(cookie)).to_s(16)}",
            severity: "low",
            title: "Cookie missing recommended flags",
            source_module: "headers",
            tags: ["cookies", "headers", "posture"],
            evidence: "Set-Cookie missing: #{missing.join(", ")}",
            recommendation: "Add Secure, HttpOnly, and SameSite where appropriate.",
          )
        end
      end

      private def missing_cookie_flags(cookie : String) : Array(String)
        value = cookie.downcase
        missing = [] of String
        missing << "Secure" unless value.includes?("secure")
        missing << "HttpOnly" unless value.includes?("httponly")
        missing << "SameSite" unless value.includes?("samesite")
        missing
      end

      # The cookie's name, so a finding id is stable across runs. String#hash is
      # seeded per process, which made the same cookie report a different id on
      # every scan and every export diff noisy.
      private def cookie_name(cookie : String) : String
        cookie.split('=', 2).first.strip.downcase
      end
    end
  end
end
