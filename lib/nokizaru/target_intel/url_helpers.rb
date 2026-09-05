# frozen_string_literal: true

module Nokizaru
  module TargetIntel
    module URLHelpers
      module_function

      def resolve_location(request_url, location)
        URI.join(request_url, location).to_s
      rescue StandardError
        location.to_s
      end

      def same_scope_host?(left_host, right_host)
        return false if left_host.to_s.strip.empty? || right_host.to_s.strip.empty?

        left = left_host.to_s.downcase
        right = right_host.to_s.downcase
        return true if left == right
        return false if ip_address?(left) || ip_address?(right)

        left_reg = registrable_domain(left)
        right_reg = registrable_domain(right)
        !left_reg.empty? && left_reg == right_reg
      end

      def canonical_url_for(original_target, canonical_uri)
        original = URI.parse(original_target)
        path = normalize_path(original.path)
        query = original.query.to_s
        base = "#{canonical_uri.scheme}://#{canonical_uri.host}"
        base += ":#{canonical_uri.port}" if canonical_uri.port && canonical_uri.port != canonical_uri.default_port
        full = "#{base}#{path}"
        query.empty? ? full : "#{full}?#{query}"
      rescue StandardError
        original_target
      end

      def normalize_path(path)
        value = path.to_s
        value.empty? ? '/' : value
      end

      def registrable_domain(host)
        PublicSuffix.domain(host)
      rescue StandardError
        host.to_s
      end

      def ip_address?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end

      def decision_payload(reanchor, effective_target, reason_code, reason)
        {
          reanchor: reanchor,
          effective_target: effective_target,
          reason_code: reason_code,
          reason: reason.to_s
        }
      end
    end
  end
end
