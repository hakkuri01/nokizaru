# frozen_string_literal: true

require 'uri'
require 'public_suffix'
require 'ipaddr'
require_relative 'http_client'
require_relative 'target_intel/url_helpers'
require_relative 'target_intel/http_helpers'
require_relative 'target_intel/profile_helpers'

module Nokizaru
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
    def profile(target, verify_ssl: false, timeout_s: 10, response: nil, request_headers: {})
      original_uri = URI.parse(target)
      response ||= fetch(original_uri, verify_ssl: verify_ssl, timeout_s: timeout_s, request_headers: request_headers)
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
      location = Nokizaru::HTTPClient.header_value(response, 'location').to_s.strip
      return nil if location.empty?

      resolved_location = resolve_location(target, location)
      [resolved_location, URI.parse(resolved_location)]
    end

    def reanchor_decision(target, profile)
      profile = {} unless profile.is_a?(Hash)
      effective = profile['effective_url'].to_s
      mode = profile['mode'].to_s
      confidence = profile['confidence'].to_s
      reason_code = reason_code_for(profile)
      reanchor = (mode == 'http_to_https' && confidence == 'high' && !effective.empty?) ||
                 canonical_same_scope_reanchor?(target, effective, mode, confidence)
      effective_target = reanchor ? effective : target
      decision_payload(reanchor, effective_target, reason_code, profile['reason'])
    end

    def canonical_same_scope_reanchor?(target, effective, mode, confidence)
      return false unless mode == 'same_scope_redirect' && confidence == 'medium'

      source = URI.parse(target)
      destination = URI.parse(effective)
      source.scheme == destination.scheme &&
        canonical_redirect_path?(source, destination) &&
        !source.host.to_s.casecmp?(destination.host.to_s) &&
        same_scope_host?(source.host, destination.host)
    rescue StandardError
      false
    end

    def canonical_redirect_path?(source, destination)
      destination_path = normalize_path(destination.path)
      destination_path == '/' || destination_path == normalize_path(source.path)
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

    def http_to_https_upgrade?(source_uri, target_uri)
      return false unless source_uri.scheme == 'http'
      return false unless target_uri.scheme == 'https'

      same_scope_host?(source_uri.host, target_uri.host)
    end
  end
end
