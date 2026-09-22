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

      def normalize_http_url(url)
        uri = URI.parse(url.to_s)
        return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo

        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.fragment = nil
        uri.path = '/' if uri.path.empty?
        uri.port = nil if uri.port == uri.default_port
        uri.normalize.to_s
      rescue StandardError
        nil
      end

      def redirect_target(request_url, location, scope_url: request_url)
        target = normalize_http_url(resolve_location(request_url, location))
        return { stop_reason: :invalid_redirect } unless target

        source = URI.parse(normalize_http_url(request_url))
        destination = URI.parse(target)
        return { stop_reason: :unsafe_redirect } if source.scheme == 'https' && destination.scheme == 'http'

        scope = URI.parse(normalize_http_url(scope_url))
        unless same_scope_host?(scope.host, destination.host)
          return { stop_reason: :canonical_handoff, canonical_handoff: target }
        end

        { next_url: target }
      rescue StandardError
        { stop_reason: :invalid_redirect }
      end

      def same_origin?(left_url, right_url)
        left = URI.parse(normalize_http_url(left_url))
        right = URI.parse(normalize_http_url(right_url))
        left.scheme == right.scheme && left.host == right.host && left.port == right.port
      rescue StandardError
        false
      end

      def same_scope_host?(left_host, right_host)
        return false if left_host.to_s.strip.empty? || right_host.to_s.strip.empty?

        left = left_host.to_s.downcase
        right = right_host.to_s.downcase
        return true if left == right
        return false if ip_address?(left) || ip_address?(right)

        left_reg = registrable_domain(left).to_s
        right_reg = registrable_domain(right).to_s
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
