module Nokizaru
  # The passive crawler: fetch the target, extract links from the HTML, read
  # robots.txt and the sitemap graph, and pull URLs out of same-scope
  # JavaScript. Ports modules/crawler.rb and its crawler/* helpers. Every
  # collection is capped so an adversarial target cannot make the crawl grow
  # without bound. UI rendering, logging, and the ctx/progress wiring are
  # assembled with the runner.
  module Crawler
    # Per-request fetch budget, matching the Ruby crawler.
    TIMEOUT          = 10.0
    MAX_HTTP_RETRIES =    2

    # The primary user-agent and the fallback tried after a bot block
    # (403/405/429). Both are real browser strings (never our own tool name,
    # which gets WAF-blocked); the retry varies the fingerprint Chrome->Firefox.
    # active_user_agent records which one reached the page.
    USER_AGENT          = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    FALLBACK_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:126.0) Gecko/20100101 Firefox/126.0"

    # How many sitemap/JS fetches run at once.
    MAX_FETCH_WORKERS = 8

    # Standard caps on every collection. The target controls its own HTML,
    # robots, sitemaps, and JavaScript, so each bucket stops at a fixed size and
    # memory never grows with the response.
    MAX_SITEMAPS         =  200
    MAX_ROBOTS_LINKS     =  180
    MAX_SITEMAP_LINKS    =  160
    MAX_RESOURCE_LINKS   =  400
    MAX_INTERNAL_LINKS   =  900
    MAX_EXTERNAL_LINKS   =  220
    MAX_IMAGE_LINKS      =  300
    MAX_SITEMAP_URLS     = 2500
    MAX_JS_TARGETS       =   80
    MAX_JS_URLS_PER_FILE =  120
    MAX_JS_URLS_TOTAL    = 1200
    MAX_MAIN_REDIRECTS   =    2
    MAX_WALL_CLOCK       = 25.0.seconds

    # Heavy-surface thresholds: a target wide enough on two of these counts (or
    # extreme on one) trips degraded mode, which lowers the deep-crawl caps.
    HEAVY_INTERNAL_LINKS_THRESHOLD   = 220
    HEAVY_JS_LINKS_THRESHOLD         =  30
    HEAVY_ROBOTS_LINKS_THRESHOLD     =  60
    EXTREME_INTERNAL_LINKS_THRESHOLD = 500
    EXTREME_ROBOTS_LINKS_THRESHOLD   = 150

    # Time-pressure thresholds: well into the wall-clock budget with a large
    # surface already discovered also trips degraded mode.
    DEGRADE_ELAPSED_RATIO_THRESHOLD   = 0.60
    DEGRADE_DISCOVERED_URLS_THRESHOLD =  700

    # The lowered caps degraded mode applies.
    DEGRADED_MAX_SITEMAPS      =  48
    DEGRADED_MAX_SITEMAP_LINKS =  60
    DEGRADED_MAX_SITEMAP_URLS  = 700
    DEGRADED_MAX_JS_TARGETS    =  20
    DEGRADED_MAX_JS_URLS_TOTAL = 250

    # The 3xx codes the crawler follows and the codes it reads as a bot block.
    REDIRECT_CODES  = {301, 302, 303, 307, 308}
    BOT_BLOCK_CODES = {403, 405, 429}
  end
end
