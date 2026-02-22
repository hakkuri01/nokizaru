# frozen_string_literal: true

module Nokizaru
  module TargetIntel
    # Profile mutation helpers for target intel decisions
    module ProfileHelpers
      module_function

      def default_profile(target)
        {
          'original_url' => target,
          'effective_url' => target,
          'mode' => 'none',
          'confidence' => 'low',
          'reason' => 'No stable redirect behavior detected',
          'location' => nil
        }
      end

      def failed_profile(target)
        profile = default_profile(target)
        profile['reason'] = 'Target profiling failed'
        profile
      end

      def apply_redirect_profile!(profile, original_uri, resolved_uri, target)
        if TargetIntel.http_to_https_upgrade?(original_uri, resolved_uri)
          apply_http_upgrade_profile!(profile, resolved_uri, target)
        elsif TargetIntel.same_scope_host?(original_uri.host, resolved_uri.host)
          apply_same_scope_profile!(profile)
        else
          apply_cross_scope_profile!(profile)
        end
      end

      def apply_http_upgrade_profile!(profile, resolved_uri, target)
        profile['mode'] = 'http_to_https'
        profile['confidence'] = 'high'
        profile['reason'] = 'Canonical HTTP to HTTPS redirect detected'
        profile['effective_url'] = TargetIntel.canonical_url_for(target, resolved_uri)
      end

      def apply_same_scope_profile!(profile)
        profile['mode'] = 'same_scope_redirect'
        profile['confidence'] = 'medium'
        profile['reason'] = 'Redirect detected within the same target scope'
      end

      def apply_cross_scope_profile!(profile)
        profile['mode'] = 'cross_scope_redirect'
        profile['confidence'] = 'low'
        profile['reason'] = 'Redirect target is outside original scope'
      end
    end
  end
end
