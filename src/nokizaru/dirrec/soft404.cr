require "./limits"
require "./sample"
require "./fields"

module Nokizaru
  module DirRec
    # Soft-404 (wildcard page) detection: building a baseline from the
    # random-path probes, and learning one on the fly from live responses when
    # the probes were inconclusive but the target serves a dominant generic
    # page. Scoring stays pure so it can be reasoned about alone; the HTTP
    # probing that feeds these samples belongs to the runtime. Complexity:
    # O(probes) to build, O(1) per learned sample (a signature counter), bounded
    # by SOFT_404_MAX_LEARNING_SAMPLES.
    module Soft404
      extend self

      # The on-the-fly learner: a signature histogram plus one sample per
      # signature, so a dominant generic page can be promoted to a baseline.
      class Learning
        property total : Int32 = 0
        getter signatures : Hash(String, Int32) = Hash(String, Int32).new(0)
        getter samples : Hash(String, Sample) = {} of String => Sample
      end

      # Whether runtime learning is still active and how many samples it has seen.
      class State
        property? enabled : Bool = true
        property sampled : Int32 = 0
      end

      def build_from_samples(samples : Array(Sample)) : Baseline?
        return nil if samples.size < SOFT_404_MIN_PROBES

        status = single_status(samples)
        return nil if status.nil?
        return redirect_baseline(samples, status) if Fields.redirect_status?(status)

        content_baseline(samples, status)
      end

      def soft_404_active?(state : State, baseline : Baseline?) : Bool
        return false unless state.enabled?
        return true unless baseline.nil?

        state.sampled < SOFT_404_MAX_LEARNING_SAMPLES
      end

      def record_sample!(state : State) : Nil
        state.sampled += 1
      end

      def disable_if_unstable!(state : State, baseline : Baseline?, learning : Learning) : Nil
        return unless baseline.nil?
        return if state.sampled < SOFT_404_MIN_LEARNING_SAMPLES
        return if learning_top_ratio(learning) >= SOFT_404_MIN_DOMINANCE_RATIO

        state.enabled = false
      end

      def learn(sample : Sample?, baseline : Baseline?, learning : Learning) : Baseline?
        return baseline unless baseline.nil?
        return baseline if sample.nil?
        return baseline unless SOFT_404_SAMPLE_STATUSES.includes?(sample.status)

        key = signature_key(sample)
        return baseline if key.nil?

        update_signature!(learning, sample, key)
        promoted = promote(learning)
        promoted.nil? ? baseline : promoted_baseline(promoted)
      end

      def tolerance(body_length : Int32) : Int32
        Math.max((body_length * 0.05).round(:ties_away).to_i, SOFT_404_MIN_TOLERANCE).clamp(0, SOFT_404_MAX_TOLERANCE)
      end

      private def learning_top_ratio(learning : Learning) : Float64
        total = learning.total
        return 0.0 if total <= 0

        top = learning.signatures.values.max? || 0
        top.to_f / total
      end

      private def signature_key(sample : Sample) : String?
        if Fields.redirect_status?(sample.status)
          sample.redirect_pattern || sample.location
        else
          sample.fingerprint || sample.title
        end
      end

      private def update_signature!(learning : Learning, sample : Sample, key : String) : Nil
        learning.total += 1
        signature = "#{sample.status}\u0000#{sample.content_type}\u0000#{key}\u0000#{sample.body_length // 256}"
        learning.signatures[signature] += 1
        learning.samples[signature] ||= sample
      end

      private def promote(learning : Learning) : Sample?
        top = learning.signatures.max_by? { |_signature, count| count }
        return nil if top.nil?

        signature, count = top
        return nil unless learning.total >= 8 && count >= 6 && count.to_f / learning.total >= 0.8

        learning.samples[signature]?
      end

      private def promoted_baseline(sample : Sample) : Baseline
        return redirect_promoted(sample) if Fields.redirect_status?(sample.status)

        Baseline.new(
          status: sample.status, content_type: sample.content_type, body_length: sample.body_length,
          tolerance: tolerance(sample.body_length), title: sample.title, fingerprint: sample.fingerprint,
        )
      end

      private def redirect_promoted(sample : Sample) : Baseline
        Baseline.new(status: sample.status, location: sample.location, redirect_pattern: sample.redirect_pattern)
      end

      private def single_status(samples : Array(Sample)) : Int32?
        statuses = samples.map(&.status)
        statuses.uniq!
        statuses.size == 1 ? statuses.first : nil
      end

      private def redirect_baseline(samples : Array(Sample), status : Int32) : Baseline?
        patterns = samples.compact_map(&.redirect_pattern)
        patterns.uniq!
        return Baseline.new(status: status, redirect_pattern: patterns.first) if patterns.size == 1

        locations = samples.compact_map(&.location)
        locations.uniq!
        return nil unless locations.size == 1

        Baseline.new(status: status, location: locations.first)
      end

      private def content_baseline(samples : Array(Sample), status : Int32) : Baseline?
        content_type = single_value(samples.map(&.content_type))
        return nil if content_type.nil?

        median = median_body_length(samples)
        return nil if median.nil?

        Baseline.new(
          status: status, content_type: content_type, body_length: median, tolerance: tolerance(median),
          title: single_value(samples.map(&.title)), fingerprint: single_fingerprint(samples),
        )
      end

      private def single_value(values : Array(String?)) : String?
        unique = values.uniq
        unique.size == 1 ? unique.first : nil
      end

      private def single_fingerprint(samples : Array(Sample)) : String?
        fingerprints = samples.compact_map(&.fingerprint)
        fingerprints.uniq.size == 1 ? fingerprints.first : nil
      end

      private def median_body_length(samples : Array(Sample)) : Int32?
        lengths = samples.map(&.body_length)
        return nil if lengths.empty?

        lengths.sort![lengths.size // 2]
      end
    end
  end
end
