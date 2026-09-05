# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Soft404
        private

        # Detect wildcard or soft-404 responses so noisy 200 pages are filtered
        def build_soft_404_baseline(client, target, request_headers: {}, allow_redirects: false)
          samples = []
          SOFT_404_PROBES.times do
            sample = soft_404_probe_sample(
              client,
              target,
              request_headers: request_headers,
              allow_redirects: allow_redirects
            )
            samples << sample if sample
          rescue StandardError
            nil
          end

          soft_404_baseline_from_samples(samples)
        end

        def soft_404_probe_sample(client, target, request_headers:, allow_redirects:)
          probe_url = "#{normalize_target_base(target)}/#{SecureRandom.hex(10)}"
          raw = request_url(client, probe_url, {
                              request_method: :get,
                              request_headers: request_headers,
                              allow_redirects: allow_redirects
                            })
          result = HttpResult.new(raw)
          return nil unless result.success?

          response_sample(result, request_url: probe_url)
        end

        def response_sample(http_result, request_url: nil)
          status = http_result.status.to_i
          return nil unless SOFT_404_SAMPLE_STATUSES.include?(status)

          context = response_sample_context(http_result, request_url)
          response_sample_payload(status, context)
        end

        def response_sample_payload(status, context)
          {
            status: status,
            content_type: context[:content_type],
            body_length: context[:body].bytesize
          }.merge(response_sample_body_fields(context)).merge(
            location: context[:location],
            redirect_pattern: context[:pattern]
          )
        end

        def response_sample_body_fields(context)
          {
            title: extract_title(context[:body]),
            fingerprint: body_fingerprint(context[:body])
          }
        end

        def response_sample_context(http_result, request_url)
          {
            content_type: normalize_content_type(http_result.headers['content-type']),
            body: http_result.body.to_s,
            location: normalized_location_from_request(request_url, http_result.headers['location']),
            pattern: redirect_pattern(request_url, http_result.headers['location'])
          }
        end

        def response_redirect_sample(http_result, request_url: nil)
          status = http_result.status.to_i
          return nil unless redirect_status?(status)

          location = normalized_location_from_request(request_url, http_result.headers['location'])
          pattern = redirect_pattern(request_url, http_result.headers['location'])
          {
            status: status,
            location: location,
            redirect_pattern: pattern
          }
        end

        def soft_404_baseline_from_samples(samples)
          return nil if samples.length < SOFT_404_MIN_PROBES

          status = single_soft_404_status(samples)
          return nil unless status
          return redirect_soft_404_baseline(samples, status) if redirect_status?(status)

          content_soft_404_baseline(samples, status)
        end

        def single_soft_404_status(samples)
          statuses = samples.map { |sample| sample[:status] }.uniq
          return nil unless statuses.length == 1

          statuses.first
        end

        def redirect_soft_404_baseline(samples, status)
          patterns = samples.map { |sample| sample[:redirect_pattern] }.compact.uniq
          return { status: status, redirect_pattern: patterns.first } if patterns.length == 1

          locations = samples.map { |sample| sample[:location] }.compact.uniq
          return nil unless locations.length == 1

          { status: status, location: locations.first }
        end

        def content_soft_404_baseline(samples, status)
          content_type = single_content_type(samples)
          return nil unless content_type

          median_length = median_body_length(samples)
          return nil unless median_length

          content_baseline_payload(samples, status, content_type, median_length)
        end

        def content_baseline_payload(samples, status, content_type, median_length)
          {
            status: status,
            content_type: content_type,
            body_length: median_length,
            tolerance: soft_404_tolerance(median_length),
            title: single_sample_title(samples),
            fingerprint: single_sample_fingerprint(samples)
          }
        end

        def single_content_type(samples)
          content_types = samples.map { |sample| sample[:content_type] }.uniq
          content_types.length == 1 ? content_types.first : nil
        end

        def median_body_length(samples)
          lengths = samples.map { |sample| sample[:body_length] }
          return nil if lengths.empty?

          lengths.sort[lengths.length / 2]
        end

        def soft_404_tolerance(body_length)
          [(body_length * 0.05).round, SOFT_404_MIN_TOLERANCE].max.clamp(0, SOFT_404_MAX_TOLERANCE)
        end

        def single_sample_title(samples)
          titles = samples.map { |sample| sample[:title] }.uniq
          titles.length == 1 ? titles.first : nil
        end

        def single_sample_fingerprint(samples)
          fingerprints = samples.map { |sample| sample[:fingerprint] }.compact
          fingerprints.uniq.length == 1 ? fingerprints.first : nil
        end

        # Initialize dynamic baseline learner for strict targets with generic 200 pages
        def init_soft_404_learning
          { total: 0, signatures: Hash.new(0), samples: {} }
        end

        # Track baseline learning state so expensive response matching can be disabled when ineffective
        def init_soft_404_state
          { enabled: true, sampled: 0 }
        end

        def soft_404_active?(state, baseline)
          return false unless state[:enabled]
          return true if baseline

          state[:sampled] < SOFT_404_MAX_LEARNING_SAMPLES
        end

        def record_soft_404_sample!(state)
          state[:sampled] += 1
        end

        def disable_soft_404_if_unstable!(state, baseline, learning)
          return if baseline
          return if state[:sampled] < SOFT_404_MIN_LEARNING_SAMPLES
          return if learning_top_ratio(learning) >= SOFT_404_MIN_DOMINANCE_RATIO

          state[:enabled] = false
        end

        def learning_top_ratio(learning)
          total = learning[:total].to_i
          return 0.0 if total <= 0

          top_count = learning[:signatures].values.max.to_i
          top_count.to_f / total
        end

        def learn_soft_404_baseline(sample, baseline, learning)
          return baseline if baseline || sample.nil?
          return baseline unless SOFT_404_SAMPLE_STATUSES.include?(sample[:status])

          signature_key = sample_signature_key(sample)
          return baseline unless signature_key

          update_learning_signature!(learning, sample, signature_key)
          promoted = promote_learning_signature(learning)
          return baseline unless promoted

          promoted_soft_404_baseline(promoted)
        end

        def sample_signature_key(sample)
          if redirect_status?(sample[:status])
            sample[:redirect_pattern] || sample[:location]
          else
            sample[:fingerprint] || sample[:title]
          end
        end

        def update_learning_signature!(learning, sample, signature_key)
          learning[:total] += 1
          signature = [sample[:status], sample[:content_type], signature_key, sample[:body_length] / 256]
          learning[:signatures][signature] += 1
          learning[:samples][signature] ||= sample
          signature
        end

        def promote_learning_signature(learning)
          top_signature, top_count = learning[:signatures].max_by { |_signature, count| count }
          return nil unless top_signature && learning[:total] >= 8
          return nil unless top_count >= 6
          return nil unless (top_count.to_f / learning[:total]) >= 0.8

          learning[:samples][top_signature]
        end

        def promoted_soft_404_baseline(sample)
          return promoted_redirect_baseline(sample) if redirect_status?(sample[:status])

          {
            status: sample[:status],
            content_type: sample[:content_type],
            body_length: sample[:body_length],
            tolerance: soft_404_tolerance(sample[:body_length]),
            title: sample[:title],
            fingerprint: sample[:fingerprint]
          }
        end

        def promoted_redirect_baseline(sample)
          {
            status: sample[:status],
            location: sample[:location],
            redirect_pattern: sample[:redirect_pattern]
          }
        end
      end
    end
  end
end
