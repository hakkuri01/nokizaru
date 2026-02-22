# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'uri'
require 'public_suffix'
require_relative 'target_intel/url_helpers'
require_relative 'target_intel/http_helpers'
require_relative 'target_intel/profile_helpers'

module Nokizaru
  # Nokizaru::TargetIntel implementation
  module TargetIntel
    module_function

    extend URLHelpers
    extend HTTPHelpers
    extend ProfileHelpers

    USER_AGENT = 'Nokizaru'

    def resolve_location(request_url, location)
      URLHelpers.resolve_location(request_url, location)
    end

    def same_scope_host?(left_host, right_host)
      URLHelpers.same_scope_host?(left_host, right_host)
    end

    def canonical_url_for(original_target, canonical_uri)
      URLHelpers.canonical_url_for(original_target, canonical_uri)
    end

    def normalize_path(path)
      URLHelpers.normalize_path(path)
    end

    def decision_payload(reanchor, effective_target, reason_code, reason)
      URLHelpers.decision_payload(reanchor, effective_target, reason_code, reason)
    end

    # Build a lightweight target profile used by scan modules for context-aware anchoring
    def profile(target, verify_ssl: false, timeout_s: 10, response: nil)
      original_uri = URI.parse(target)
      response ||= fetch(original_uri, verify_ssl: verify_ssl, timeout_s: timeout_s)
      profile = default_profile(target)
      return profile unless response

      build_profile_from_response(profile, target, original_uri, response)
      profile
    rescue StandardError
      failed_profile(target)
    end

    def build_profile_from_response(profile, target, original_uri, response)
      resolved = resolved_redirect_uri(target, response)
      return unless resolved

      resolved_location, resolved_uri = resolved
      profile['location'] = resolved_location
      apply_redirect_profile!(profile, original_uri, resolved_uri, target)
    end

    def resolved_redirect_uri(target, response)
      location = response['location'].to_s.strip
      return nil if location.empty?

      resolved_location = resolve_location(target, location)
      [resolved_location, URI.parse(resolved_location)]
    end

    # Decide whether modules should re-anchor to a canonical URL
    def reanchor_decision(target, profile)
      profile = {} unless profile.is_a?(Hash)
      effective = profile['effective_url'].to_s
      mode = profile['mode'].to_s
      confidence = profile['confidence'].to_s
      reason_code = reason_code_for(profile)
      reanchor = mode == 'http_to_https' && confidence == 'high' && !effective.empty?
      effective_target = reanchor ? effective : target
      decision_payload(reanchor, effective_target, reason_code, profile['reason'])
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
  end
end
