# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Preflight
        private

        # Probe the target shape quickly so we can select an enumeration mode
        def preflight_probe(target, verify_ssl:, allow_redirects:, request_headers: {})
          probe_client = build_preflight_client(
            target,
            verify_ssl: verify_ssl,
            allow_redirects: allow_redirects,
            request_headers: request_headers
          )
          metrics = empty_preflight_metrics
          run_preflight_workers(preflight_urls(target), probe_client, metrics, request_headers, allow_redirects)
          metrics
        rescue StandardError
          preflight_fallback_metrics
        ensure
          probe_client.close if probe_client.respond_to?(:close)
        end

        def build_preflight_client(target, verify_ssl:, allow_redirects:, request_headers: {})
          Nokizaru::HTTPClient.for_bulk_requests(
            target,
            timeout_s: PREFLIGHT_TIMEOUT_S,
            headers: { 'User-Agent' => DEFAULT_UA },
            follow_redirects: follow_redirects_for_client(allow_redirects, request_headers),
            verify_ssl: verify_ssl,
            max_concurrent: 8,
            retries: 0
          )
        end

        def empty_preflight_metrics
          {
            total: 0,
            errors: 0,
            timeouts: 0,
            redirects: 0,
            generic_redirects: 0,
            statuses: Hash.new(0)
          }
        end

        def preflight_fallback_metrics
          empty_preflight_metrics.merge(statuses: {})
        end

        def run_preflight_workers(urls, probe_client, metrics, request_headers, allow_redirects)
          queue = build_work_queue(urls)
          mutex = Mutex.new
          workers = Array.new(8) do
            Thread.new { preflight_worker_loop(queue, probe_client, metrics, mutex, request_headers, allow_redirects) }
          end
          workers.each(&:join)
        end

        def preflight_worker_loop(queue, probe_client, metrics, mutex, request_headers, allow_redirects)
          loop do
            url = pop_queue_url(queue)
            break if url.nil? || Nokizaru::InterruptState.interrupted?

            process_preflight_url(url, probe_client, metrics, mutex, request_headers, allow_redirects)
          end
        end

        def process_preflight_url(url, probe_client, metrics, mutex, request_headers, allow_redirects)
          result = preflight_result(probe_client, url, request_headers, allow_redirects)
          mutex.synchronize { update_preflight_metrics!(metrics, result, url) }
        rescue StandardError
          mutex.synchronize { record_preflight_error!(metrics) }
        end

        def preflight_result(probe_client, url, request_headers, allow_redirects)
          raw = request_url(probe_client, url, {
                              request_method: :head,
                              request_headers: request_headers,
                              allow_redirects: allow_redirects
                            })
          result = HttpResult.new(raw)
          { response: result, error_kind: result.success? ? nil : classify_error(result) }
        end

        def update_preflight_metrics!(metrics, result, url)
          metrics[:total] += 1
          return record_preflight_error!(metrics, result[:error_kind]) unless result[:response].success?

          record_preflight_success!(metrics, result[:response], url)
        end

        def record_preflight_error!(metrics, error_kind = nil)
          metrics[:errors] += 1
          metrics[:timeouts] += 1 if error_kind == 'timeout'
        end

        def record_preflight_success!(metrics, response, url)
          status = response.status.to_i
          metrics[:statuses][status] += 1
          return unless redirect_status?(status)

          metrics[:redirects] += 1
          sample = response_redirect_sample(response, request_url: url)
          metrics[:generic_redirects] += 1 if sample && generic_redirect_pattern?(sample[:redirect_pattern].to_s)
        end

        # Compose a small preflight set: random canaries + high-signal endpoints
        def preflight_urls(target)
          base = normalize_target_base(target)

          urls = []
          PREFLIGHT_RANDOM_PROBES.times do
            urls << "#{base}/#{SecureRandom.hex(8)}"
          end

          preflight_signal_paths.each do |path|
            urls << join_url(base, path)
          end

          urls.uniq.first(PREFLIGHT_TOTAL_PROBES)
        end

        def preflight_signal_paths
          %w[
            /robots.txt
            /sitemap.xml
            /wp-login.php
            /xmlrpc.php
            /wp-admin
            /wp-json
            /admin
            /login
          ]
        end

        def choose_mode(preflight)
          total = preflight[:total].to_i
          return MODE_HOSTILE if total <= 0

          ratios = preflight_ratios(preflight, total)
          return MODE_HOSTILE if hostile_preflight?(ratios)
          return MODE_SEEDED if seeded_preflight?(ratios)

          MODE_FULL
        end

        def preflight_ratios(preflight, total)
          errors = preflight[:errors].to_i
          redirects = preflight[:redirects].to_i
          {
            success: (total - errors).to_f / total,
            error: errors.to_f / total,
            timeout: preflight[:timeouts].to_i.to_f / total,
            redirect: redirects.to_f / total,
            generic: generic_redirect_ratio(preflight, redirects)
          }
        end

        def generic_redirect_ratio(preflight, redirects)
          return 0.0 unless redirects.positive?

          preflight[:generic_redirects].to_i.to_f / redirects
        end

        def hostile_preflight?(ratios)
          severe_transport_failure = ratios[:error] >= PREFLIGHT_HOSTILE_ERROR_RATIO ||
                                     ratios[:timeout] >= PREFLIGHT_HOSTILE_TIMEOUT_RATIO
          return true if severe_transport_failure && ratios[:success] <= PREFLIGHT_HOSTILE_MIN_SUCCESS_RATIO

          return true if ratios[:timeout] >= 0.6
          return false unless ratios[:redirect] >= 0.4 && ratios[:generic] >= 0.7

          ratios[:error] >= 0.25
        end
      end
    end
  end
end
