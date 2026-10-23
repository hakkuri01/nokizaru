require "./limits"

module Nokizaru
  module Crawler
    # The link counts the budget inspects to decide heavy-surface degradation.
    record Surface,
      internal : Int32,
      external : Int32,
      images : Int32,
      sitemap : Int32,
      js : Int32,
      robots : Int32

    # Mutable crawl-control state, ported from the Ruby `__control__` hash: the
    # wall-clock deadline, whether degraded mode is active, the notes that surface
    # in stats, and the live deep-crawl caps (lowered when degraded). It is never
    # serialized (Ruby deleted `__control__` before persisting); it only shapes
    # the caps, stats["crawl_mode"], stats["crawl_notes"], and the final status.
    #
    # Every method is O(1): the surface counts are passed in and the checks are a
    # fixed set of comparisons.
    class Budget
      getter? degraded : Bool = false
      getter notes : Array(String) = [] of String
      property max_sitemaps : Int32 = MAX_SITEMAPS
      property max_sitemap_links : Int32 = MAX_SITEMAP_LINKS
      property max_sitemap_urls : Int32 = MAX_SITEMAP_URLS
      property max_js_targets : Int32 = MAX_JS_TARGETS
      property max_js_urls_total : Int32 = MAX_JS_URLS_TOTAL

      # The deadline defaults to the wall-clock budget from now; a test can pass
      # a past instant to simulate an exhausted budget deterministically.
      def initialize(@deadline_at : Time::Instant = Time.instant + MAX_WALL_CLOCK)
        @started_at = @deadline_at - MAX_WALL_CLOCK
      end

      # True once the wall-clock budget is spent; records the note on first hit.
      def exhausted?(now : Time::Instant = Time.instant) : Bool
        return false if now < @deadline_at

        mark_exhausted
        true
      end

      # Trips degraded mode (once) when the surface is heavy or the deadline is
      # near with a large surface already found, lowering the deep-crawl caps.
      def apply(surface : Surface, now : Time::Instant = Time.instant) : Nil
        return if exhausted?(now)
        return if @degraded
        return unless heavy_surface?(surface) || nearing_deadline?(surface, now)

        @degraded = true
        @notes << (heavy_surface?(surface) ? "heavy_target" : "budget_pressure")
        degrade_limits
      end

      def crawl_mode : String
        @degraded ? "degraded" : "standard"
      end

      def status_degraded? : Bool
        @degraded || @notes.includes?("wall_clock_budget_exhausted")
      end

      private def heavy_surface?(surface : Surface) : Bool
        indicators = 0
        indicators += 1 if surface.internal >= HEAVY_INTERNAL_LINKS_THRESHOLD
        indicators += 1 if surface.js >= HEAVY_JS_LINKS_THRESHOLD
        indicators += 1 if surface.robots >= HEAVY_ROBOTS_LINKS_THRESHOLD
        extreme = surface.internal >= EXTREME_INTERNAL_LINKS_THRESHOLD ||
                  surface.robots >= EXTREME_ROBOTS_LINKS_THRESHOLD
        extreme || indicators >= 2
      end

      private def nearing_deadline?(surface : Surface, now : Time::Instant) : Bool
        ratio = (now - @started_at).total_seconds / MAX_WALL_CLOCK.total_seconds
        discovered = surface.internal + surface.external + surface.images + surface.sitemap
        ratio >= DEGRADE_ELAPSED_RATIO_THRESHOLD && discovered >= DEGRADE_DISCOVERED_URLS_THRESHOLD
      end

      private def degrade_limits : Nil
        @max_sitemaps = DEGRADED_MAX_SITEMAPS
        @max_sitemap_links = DEGRADED_MAX_SITEMAP_LINKS
        @max_sitemap_urls = DEGRADED_MAX_SITEMAP_URLS
        @max_js_targets = DEGRADED_MAX_JS_TARGETS
        @max_js_urls_total = DEGRADED_MAX_JS_URLS_TOTAL
      end

      private def mark_exhausted : Nil
        return if @notes.includes?("wall_clock_budget_exhausted")

        @notes << "wall_clock_budget_exhausted"
      end
    end
  end
end
