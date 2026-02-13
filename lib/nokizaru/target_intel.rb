# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'uri'
require 'public_suffix'

module Nokizaru
  module TargetIntel
    module_function

    USER_AGENT = 'Nokizaru'

    # Build a lightweight target profile used by scan modules for context-aware anchoring
    def profile(target, verify_ssl: false, timeout_s: 10, response: nil)
      original_uri = URI.parse(target)
      response ||= fetch(original_uri, verify_ssl: verify_ssl, timeout_s: timeout_s)

      profile = {
        'original_url' => target,
        'effective_url' => target,
        'mode' => 'none',
        'confidence' => 'low',
        'reason' => 'No stable redirect behavior detected',
        'location' => nil
      }
      return profile unless response

      location = response['location'].to_s.strip
      return profile if location.empty?

      resolved_location = resolve_location(target, location)
      resolved_uri = URI.parse(resolved_location)

      profile['location'] = resolved_location

      if http_to_https_upgrade?(original_uri, resolved_uri)
        profile['mode'] = 'http_to_https'
        profile['confidence'] = 'high'
        profile['reason'] = 'Canonical HTTP to HTTPS redirect detected'
        profile['effective_url'] = canonical_url_for(target, resolved_uri)
      elsif same_scope_host?(original_uri.host, resolved_uri.host)
        profile['mode'] = 'same_scope_redirect'
        profile['confidence'] = 'medium'
        profile['reason'] = 'Redirect detected within the same target scope'
      else
        profile['mode'] = 'cross_scope_redirect'
        profile['confidence'] = 'low'
        profile['reason'] = 'Redirect target is outside original scope'
      end

      profile
    rescue StandardError
      {
        'original_url' => target,
        'effective_url' => target,
        'mode' => 'none',
        'confidence' => 'low',
        'reason' => 'Target profiling failed',
        'location' => nil
      }
    end

    # Decide whether modules should re-anchor to a canonical URL
    def reanchor_decision(target, profile)
      profile = profile.is_a?(Hash) ? profile : {}
      effective = profile['effective_url'].to_s
      mode = profile['mode'].to_s
      confidence = profile['confidence'].to_s

      reason_code = reason_code_for(profile)

      if mode == 'http_to_https' && confidence == 'high' && !effective.empty?
        {
          reanchor: true,
          effective_target: effective,
          reason_code: reason_code,
          reason: profile['reason'].to_s
        }
      else
        {
          reanchor: false,
          effective_target: target,
          reason_code: reason_code,
          reason: profile['reason'].to_s
        }
      end
    end

    def reason_code_for(profile)
      mode = profile.is_a?(Hash) ? profile['mode'].to_s : ''
      reason = profile.is_a?(Hash) ? profile['reason'].to_s.downcase : ''
      return 'http->https' if mode == 'http_to_https'
      return 'same-scope' if mode == 'same_scope_redirect'
      return 'cross-scope' if mode == 'cross_scope_redirect'

      return 'profile-failed' if reason.include?('failed')

      'no-redirect'
    end

    # Detect HTTP->HTTPS upgrade redirects that preserve host/scope
    def http_to_https_upgrade?(source_uri, target_uri)
      return false unless source_uri.scheme == 'http'
      return false unless target_uri.scheme == 'https'

      same_scope_host?(source_uri.host, target_uri.host)
    end

    # Match path-preserving HTTP->HTTPS redirects used by canonical upgrade rules
    def path_preserving_https_redirect?(request_url, location_header, profile)
      return false unless profile.is_a?(Hash)
      return false unless profile['mode'].to_s == 'http_to_https'

      request_uri = URI.parse(request_url)
      location_uri = URI.parse(resolve_location(request_url, location_header))
      return false unless location_uri.scheme == 'https'
      return false unless same_scope_host?(request_uri.host, location_uri.host)

      normalize_path(request_uri.path) == normalize_path(location_uri.path)
    rescue StandardError
      false
    end

    # Resolve relative redirect values against the request URL
    def resolve_location(request_url, location)
      URI.join(request_url, location).to_s
    rescue StandardError
      location.to_s
    end

    # Compare hostnames at registrable-domain scope to keep re-anchoring safe
    def same_scope_host?(left_host, right_host)
      return false if left_host.to_s.strip.empty? || right_host.to_s.strip.empty?

      left = left_host.to_s.downcase
      right = right_host.to_s.downcase
      return true if left == right

      left_reg = registrable_domain(left)
      right_reg = registrable_domain(right)
      !left_reg.empty? && left_reg == right_reg
    end

    # Build canonical URL while preserving target path/query
    def canonical_url_for(original_target, canonical_uri)
      orig_uri = URI.parse(original_target)
      path = normalize_path(orig_uri.path)
      query = orig_uri.query.to_s
      base = "#{canonical_uri.scheme}://#{canonical_uri.host}"
      base += ":#{canonical_uri.port}" if canonical_uri.port && canonical_uri.port != canonical_uri.default_port
      full = "#{base}#{path}"
      query.empty? ? full : "#{full}?#{query}"
    rescue StandardError
      original_target
    end

    # Normalize empty paths so comparisons remain stable
    def normalize_path(path)
      value = path.to_s
      value.empty? ? '/' : value
    end

    # Compute registrable domain with safe fallback for private/internal hosts
    def registrable_domain(host)
      PublicSuffix.domain(host)
    rescue StandardError
      host.to_s
    end

    # Fetch one URL for target profiling with redirects disabled
    def fetch(uri, verify_ssl:, timeout_s:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = timeout_s
      http.read_timeout = timeout_s

      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      end

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = '*/*'

      http.request(request)
    rescue StandardError
      nil
    end
  end
end
