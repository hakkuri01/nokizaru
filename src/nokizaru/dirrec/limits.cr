module Nokizaru
  # Directory/file enumeration (the Ruby DirectoryEnum). This namespace holds the
  # deterministic core: path encoding, the lazy candidate queue, response
  # sampling, soft-404 learning, and confidence scoring. The adaptive
  # orchestration layer (preflight hostility, mode budgets, pressure windows,
  # adaptive concurrency, WAF scoring, dispatch) and the runtime/result assembly
  # land in a following step; the pieces here are needed by every version of the
  # module and carry no orchestration decision.
  module DirRec
    # The browser user-agent the Ruby tool sends for enumeration.
    DEFAULT_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0"

    # The effective per-request timeout when the caller passes none.
    DEFAULT_TIMEOUT = 8.0

    # A body at or below this size carries little information for confidence.
    LOW_INFORMATION_BODY_BYTES = 24
    TEXTUAL_CONTENT_TYPES      = %w[text/html text/plain application/json application/xml]

    # Soft-404 baseline probing and dynamic learning bounds.
    SOFT_404_PROBES               =    3
    SOFT_404_MIN_PROBES           =    2
    SOFT_404_MIN_TOLERANCE        =  128
    SOFT_404_MAX_TOLERANCE        = 4096
    SOFT_404_MIN_LEARNING_SAMPLES =   24
    SOFT_404_MAX_LEARNING_SAMPLES =   96
    SOFT_404_MIN_DOMINANCE_RATIO  =  0.6

    # The high-value paths seeded first and treated as high-signal in scoring.
    HIGH_SIGNAL_PATHS = %w[
      /robots.txt /sitemap.xml /.git/HEAD /.env /admin /login /signin /auth /account /dashboard
      /api /graphql /wp-admin /wp-login.php /xmlrpc.php /wp-json /server-status /server-info
    ]

    # Status classes the module reasons about.
    REDIRECT_STATUSES          = {301, 302, 303, 307, 308}
    SOFT_404_SAMPLE_STATUSES   = {200, 204, 301, 302, 303, 307, 308, 401, 403, 405, 500}
    INTERESTING_STATUSES       = {200, 204, 401, 403, 405, 500}
    FINDING_CANDIDATE_STATUSES = {200, 204, 401, 403, 405, 500, 301, 302, 303, 307, 308}

    # WAF-likelihood scoring and noise-suppression thresholds (confidence.rb).
    WAF_LIKELIHOOD_HIGH                = 0.75
    WAF_REDIRECT_CLUSTER_DOMINANCE     = 0.85
    WAF_SENSITIVE_HOMOGENEITY          =  0.8
    WAF_SENSITIVE_UNIQUENESS_LOW       =  0.2
    SENSITIVE_NOISE_MIN_SAMPLES        =   40
    SENSITIVE_NOISE_REDIRECT_DOMINANCE = 0.95
    HOMOGENEOUS_GUESS_MIN_SAMPLES      =   40
    HOMOGENEOUS_GUESS_DOMINANCE        =  0.9
  end
end
