# frozen_string_literal: true

require 'securerandom'
require 'timeout'
require 'uri'
require 'zlib'

require_relative '../http_client'
require_relative '../interrupt_state'
require_relative '../log'
require_relative '../request_headers'
require_relative '../target_intel'
require_relative '../ui'
require_relative 'crawler'
require_relative 'dirrec/path_helpers'
require_relative 'dirrec/lazy_directory_queue'
require_relative 'dirrec/preparation'
require_relative 'dirrec/runtime_lifecycle'
require_relative 'dirrec/dispatch'
require_relative 'dirrec/adaptation'
require_relative 'dirrec/responses'
require_relative 'dirrec/presentation'
require_relative 'dirrec/preflight'
require_relative 'dirrec/policy'
require_relative 'dirrec/transport'
require_relative 'dirrec/results'
require_relative 'dirrec/soft_404'
require_relative 'dirrec/confidence'
require_relative 'dirrec/redirects'

module Nokizaru
  module Modules
    module DirectoryEnum
      [
        DirectoryEnum::PathHelpers,
        DirectoryEnum::Preparation,
        DirectoryEnum::RuntimeLifecycle,
        DirectoryEnum::Dispatch,
        DirectoryEnum::Adaptation,
        DirectoryEnum::Responses,
        DirectoryEnum::Presentation,
        DirectoryEnum::Preflight,
        DirectoryEnum::Policy,
        DirectoryEnum::Transport,
        DirectoryEnum::Results,
        DirectoryEnum::Soft404,
        DirectoryEnum::Confidence,
        DirectoryEnum::Redirects
      ].each do |concern|
        include concern

        extend concern
      end

      DEFAULT_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0'
      DEFAULT_EFFECTIVE_TIMEOUT_S = 8.0
      MAX_EFFECTIVE_TIMEOUT_S = 12.0
      SOFT_404_PROBES = 3
      SOFT_404_MIN_PROBES = 2
      SOFT_404_MIN_TOLERANCE = 128
      SOFT_404_MAX_TOLERANCE = 4096
      SOFT_404_MIN_LEARNING_SAMPLES = 24
      SOFT_404_MAX_LEARNING_SAMPLES = 96
      SOFT_404_MIN_DOMINANCE_RATIO = 0.6
      PROGRESS_EVERY = 1
      STALL_WATCHDOG_INTERVAL_S = 0.2
      MIN_STALL_TIMEOUT_S = 20.0
      MAX_STALL_TIMEOUT_S = 90.0
      PROTECTED_TIMEOUT_S = 2.5
      MIN_ADAPTIVE_TIMEOUT_S = 1.5
      TIMEOUT_ADAPT_SAMPLE_SIZE = 240
      TIMEOUT_ADAPT_ERROR_RATIO = 0.2
      PREFLIGHT_RANDOM_PROBES = 6
      PREFLIGHT_TOTAL_PROBES = 12
      PREFLIGHT_TIMEOUT_S = 1.5
      PREFLIGHT_HOSTILE_MIN_SUCCESS_RATIO = 0.35
      PREFLIGHT_HOSTILE_TIMEOUT_RATIO = 0.25
      PREFLIGHT_HOSTILE_ERROR_RATIO = 0.75
      PREFLIGHT_SEEDED_ERROR_RATIO = 0.2
      PREFLIGHT_SEEDED_TIMEOUT_RATIO = 0.1
      LOW_INFORMATION_BODY_BYTES = 24
      TEXTUAL_CONTENT_TYPES = %w[text/html text/plain application/json application/xml].freeze
      WAF_LIKELIHOOD_HIGH = 0.75
      WAF_REDIRECT_CLUSTER_DOMINANCE = 0.85
      WAF_SENSITIVE_HOMOGENEITY = 0.8
      WAF_SENSITIVE_UNIQUENESS_LOW = 0.2
      SENSITIVE_NOISE_MIN_SAMPLES = 40
      SENSITIVE_NOISE_REDIRECT_DOMINANCE = 0.95

      MODE_FULL = 'full'
      MODE_SEEDED = 'seeded'
      MODE_HOSTILE = 'hostile'

      MODE_BUDGETS = {
        MODE_FULL => { budget_s: 0.0, max_requests: 0 },
        MODE_SEEDED => { budget_s: 420.0, max_requests: 0 },
        MODE_HOSTILE => { budget_s: 180.0, max_requests: 1800 }
      }.freeze
      PRESSURE_WINDOW_REQUESTS = 80
      PRESSURE_MIN_WINDOW_SECONDS = 3.0
      PRESSURE_WINDOW_ERROR_RATIO = 0.35
      PRESSURE_WINDOW_TRANSPORT_RATIO = 0.2
      PRESSURE_WINDOW_LOW_RPS = 80.0
      PRESSURE_WINDOW_LOW_YIELD_GAIN = 2
      PRESSURE_SEEDED_STREAK = 2
      PRESSURE_HOSTILE_STREAK = 4
      LOW_YIELD_HOSTILE_STREAK = 3
      LOW_YIELD_STOP_STREAK = 5
      HOSTILE_NO_SIGNAL_MIN_REQUESTS = 320
      HOSTILE_NO_SIGNAL_ERROR_RATIO = 0.9
      HOSTILE_NO_SIGNAL_MAX_SUCCESS = 4
      EXTENSION_SIGNAL_MIN_REQUESTS = 80
      EXTENSION_SIGNAL_MAX_LOW_INFO_RATIO = 0.9
      ADAPTIVE_CONCURRENCY_MIN = 2
      ADAPTIVE_CONCURRENCY_WINDOW = 160
      ADAPTIVE_CONCURRENCY_BAD_ERROR_RATIO = 0.35
      ADAPTIVE_CONCURRENCY_RECOVER_ERROR_RATIO = 0.08
      MARGINAL_VALUE_MIN_REQUESTS = 320
      MARGINAL_VALUE_LOW_GAIN = 1
      MARGINAL_VALUE_DOMINANCE_RATIO = 0.92
      PRESSURE_SCORE_WAF_HINT = 0.72
      PRESSURE_SCORE_REDIRECT_HINT = 0.92
      HIGH_SIGNAL_PATHS = %w[
        /robots.txt
        /sitemap.xml
        /.git/HEAD
        /.env
        /admin
        /login
        /signin
        /auth
        /account
        /dashboard
        /api
        /graphql
        /wp-admin
        /wp-login.php
        /xmlrpc.php
        /wp-json
        /server-status
        /server-info
      ].freeze
      REDIRECT_STATUSES = Set[301, 302, 303, 307, 308].freeze
      SOFT_404_SAMPLE_STATUSES = Set[200, 204, 301, 302, 303, 307, 308, 401, 403, 405, 500].freeze

      INTERESTING_STATUSES = Set[200, 204, 401, 403, 405, 500].freeze
      FINDING_CANDIDATE_STATUSES = (INTERESTING_STATUSES + REDIRECT_STATUSES).freeze

      # rubocop:disable Metrics/ParameterLists -- The internal facade keeps scan configuration explicit
      def self.call(target, threads:, timeout_s:, wordlist:, allow_redirects:, verify_ssl:, extensions:, ctx:,
                    request_headers: {})
        options = {
          target: target,
          threads: threads,
          timeout_s: timeout_s,
          wdlist: wordlist,
          allow_redirects: allow_redirects,
          verify_ssl: verify_ssl,
          filext: extensions,
          ctx: ctx,
          request_headers: request_headers || {}
        }
        scan = prepare_scan(options)
        print_banner(scan)

        runtime = init_runtime(scan)
        run_workers(scan, runtime)
        finalize_scan(scan, runtime)
      end
      # rubocop:enable Metrics/ParameterLists

      private_constant(*constants(false))
    end
  end
end
