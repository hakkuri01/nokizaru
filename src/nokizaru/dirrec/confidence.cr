require "uri"
require "./limits"
require "./sample"
require "./fields"
require "./signals"

module Nokizaru
  module DirRec
    # The confidence level a candidate response earns, with the reason code the
    # stats and findings carry. level is "confirmed", "likely", or "low", matching
    # the Ruby decision symbols' to_s.
    struct Decision
      getter level : String
      getter reason : String

      def initialize(@level : String, @reason : String)
      end
    end

    # Scores one candidate response into a confidence decision. Ports the
    # deterministic core of dirrec/confidence.rb (finding_confidence and its
    # predicates); the WAF-context adjustment that depends on live runtime
    # counters lands with the runtime. Each call is O(len) over the URL/sample.
    module Confidence
      extend self

      SENSITIVE_STATUSES = {401, 403, 405, 500}

      def finding_confidence(url : String, status : Int32, sample : Sample?, baseline : Baseline?, normalized_target : String) : Decision
        return Decision.new("low", "soft_404_signature_match") if soft_404_match_sample?(sample, baseline)

        case status
        when 401, 403, 405, 500      then sensitive_status_confidence(url, sample, baseline, normalized_target, status)
        when 301, 302, 303, 307, 308 then redirect_confidence(url, sample, normalized_target)
        when 200, 204                then content_confidence(url, sample, baseline, normalized_target)
        else                              Decision.new("low", "non_actionable_status")
        end
      end

      def soft_404_match_sample?(sample : Sample?, baseline : Baseline?) : Bool
        return false if sample.nil? || baseline.nil?
        return false unless sample.status == baseline.status
        return redirect_match?(sample, baseline) if Fields.redirect_status?(sample.status)
        return false unless sample.content_type == baseline.content_type
        return true if fingerprint_match?(sample, baseline)

        title_and_length_match?(sample, baseline)
      end

      def sensitive_status_reason?(reason : String) : Bool
        reason == "sensitive_status" || reason == "meaningful_sensitive_status"
      end

      private def redirect_match?(sample : Sample, baseline : Baseline) : Bool
        if pattern = baseline.redirect_pattern
          sample.redirect_pattern == pattern
        elsif location = baseline.location
          sample.location == location
        else
          false
        end
      end

      private def fingerprint_match?(sample : Sample, baseline : Baseline) : Bool
        base = baseline.fingerprint
        !base.nil? && !sample.fingerprint.nil? && sample.fingerprint == base
      end

      private def title_and_length_match?(sample : Sample, baseline : Baseline) : Bool
        delta = (sample.body_length - (baseline.body_length || 0)).abs
        return false if delta > (baseline.tolerance || 0)

        base_title = baseline.title
        return sample.title.to_s.empty? if base_title.nil?

        sample.title == base_title
      end

      private def redirect_confidence(url : String, sample : Sample?, normalized_target : String) : Decision
        relative = relative_response_path(url, normalized_target)
        return Decision.new("confirmed", "high_signal_path") if Signals.high_signal_path?(relative)

        pattern = sample.try(&.redirect_pattern) || ""
        return Decision.new("confirmed", "auth_redirect") if pattern.starts_with?("auth_entry:")
        return Decision.new("low", "generic_redirect_pattern") if Fields.generic_redirect_pattern?(pattern)
        return Decision.new("low", "target_root_redirect") if same_path_as_target?(response_path(url), normalized_target)

        Decision.new("likely", "path_specific_redirect")
      end

      private def sensitive_status_confidence(url : String, sample : Sample?, baseline : Baseline?, normalized_target : String, status : Int32) : Decision
        relative = relative_response_path(url, normalized_target)
        return Decision.new("confirmed", "high_signal_path") if Signals.high_signal_path?(relative)
        return Decision.new("low", "target_root_sensitive_status") if same_path_as_target?(response_path(url), normalized_target)
        return Decision.new("low", "baseline_like_response") if baseline_like_length?(sample, baseline)
        return Decision.new("likely", "meaningful_sensitive_status") if meaningful_body?(sample)
        return Decision.new("low", "weak_sensitive_status") if weak_sensitive_status_sample?(relative, sample, status)

        Decision.new("likely", "sensitive_status")
      end

      private def content_confidence(url : String, sample : Sample?, baseline : Baseline?, normalized_target : String) : Decision
        relative = relative_response_path(url, normalized_target)
        return Decision.new("low", "baseline_like_response") if baseline_like_length?(sample, baseline)
        return Decision.new("low", "not_found_title") if likely_not_found_title?(sample)
        return Decision.new("confirmed", "high_signal_content") if Signals.high_signal_path?(relative) && meaningful_body?(sample)
        return Decision.new("likely", "meaningful_content") if meaningful_body?(sample)
        return Decision.new("likely", "high_signal_path") if Signals.high_signal_path?(relative) && !same_path_as_target?(response_path(url), normalized_target)

        Decision.new("low", "low_information_response")
      end

      private def meaningful_body?(sample : Sample?) : Bool
        return false if sample.nil?
        return false unless textual_content?(sample.content_type)

        sample.body_length > LOW_INFORMATION_BODY_BYTES
      end

      private def textual_content?(content_type : String?) : Bool
        type = content_type.to_s.downcase
        TEXTUAL_CONTENT_TYPES.any? { |token| type.starts_with?(token) }
      end

      private def baseline_like_length?(sample : Sample?, baseline : Baseline?) : Bool
        return false if sample.nil? || baseline.nil?
        return false unless sample.content_type == baseline.content_type

        tolerance = baseline.tolerance || 0
        return false unless tolerance > 0

        (sample.body_length - (baseline.body_length || 0)).abs <= Math.max(tolerance // 2, 64)
      end

      private def likely_not_found_title?(sample : Sample?) : Bool
        title = sample.try(&.title) || ""
        return false if title.empty?

        title.includes?("not found") || title.includes?("404")
      end

      private def weak_sensitive_status_sample?(path : String, sample : Sample?, status : Int32) : Bool
        return false unless SENSITIVE_STATUSES.includes?(status)
        return false if sample.nil?

        generic_body = sample.body_length <= LOW_INFORMATION_BODY_BYTES * 2
        generic_title = (sample.title || "").strip.empty?
        generic_body && generic_title && Signals.low_information_segment?(Signals.first_path_segment(path))
      end

      private def response_path(url : String) : String
        URI.parse(url).path.downcase
      rescue
        ""
      end

      private def relative_response_path(url : String, normalized_target : String) : String
        path = response_path(url)
        target_path = response_path(normalized_target).rchop("/")
        return path if target_path.empty? || target_path == "/"
        return "/" if path == target_path
        return path unless path.starts_with?("#{target_path}/")

        path.lchop(target_path)
      rescue
        response_path(url)
      end

      private def same_path_as_target?(path : String, normalized_target : String) : Bool
        return true if path.empty? || path == "/"

        target_path = response_path(normalized_target)
        target_path = "/" if target_path.empty?
        Fields.normalize_pattern_path(path) == Fields.normalize_pattern_path(target_path)
      rescue
        false
      end
    end
  end
end
