require "set"
require "./limits"
require "./result"
require "../http/pool"
require "../target_intel"

module Nokizaru
  module Crawler
    # The outcome of a same-scope resource fetch (robots.txt, a sitemap): the
    # HTTP result (nil only when the URL was invalid or an exception fired before
    # any request), the effective URL reached, the redirect hops taken, and a
    # stop reason when the chain ended early.
    struct ResourceFetch
      getter result : Http::Result?
      getter effective_url : String
      getter redirect_hops : Int32
      getter stop_reason : String?

      def initialize(@result : Http::Result?, @effective_url : String, @redirect_hops : Int32, @stop_reason : String? = nil)
      end

      def success? : Bool
        res = @result
        return false if res.nil? || res.error?

        status = res.status
        !status.nil? && status >= 200 && status < 300
      end
    end

    # GETs over the shared pool with the crawler's retry semantics: TLS
    # verification off, redirects handled by the caller (not the pool), and a
    # retry on a 429/5xx or a transport error, backing off 0.15*attempt up to
    # MAX_HTTP_RETRIES. Also follows same-scope redirects for resource fetches.
    # Complexity: O(1) requests per call (a fixed retry budget, a fixed redirect
    # budget); no state grows with input.
    class Fetcher
      def initialize(@pool : Http::Pool)
      end

      def get(url : String, headers : ::HTTP::Headers, user_agent : String, timeout : Float64 = TIMEOUT) : Http::Result
        options = Http::Options.new(
          headers: build_headers(headers, user_agent),
          timeout_s: timeout,
          verify_ssl: false,
          follow_redirects: false,
        )
        result = @pool.get(url, options)
        attempt = 1
        max = MAX_HTTP_RETRIES + 1
        while attempt < max && retry?(result)
          sleep((0.15 * attempt).seconds)
          result = @pool.get(url, options)
          attempt += 1
        end
        result
      end

      # Follows same-scope redirects up to MAX_MAIN_REDIRECTS, dropping the
      # operator headers on an origin change (so credentials never leak to a
      # sibling host). Ports fetch_following_same_scope_redirects.
      def fetch_following(url : String, headers : ::HTTP::Headers) : ResourceFetch
        normalized = TargetIntel.normalize_http_url(url)
        return ResourceFetch.new(nil, url, 0, "invalid_url") if normalized.nil?

        current = normalized
        hops = 0
        begin
          scope = current
          visited = Set{current}
          current_headers = headers
          loop do
            result = get(current, current_headers, USER_AGENT)
            return ResourceFetch.new(result, current, hops, "request_failed") if result.error?
            return ResourceFetch.new(result, current, hops, nil) unless redirect?(result.status)

            decision = resource_redirect_step(result, current, scope, visited, hops)
            stop = decision.stop_reason
            return ResourceFetch.new(result, current, hops, stop) unless stop.nil?

            next_url = decision.next_url
            return ResourceFetch.new(result, current, hops, "invalid_redirect") if next_url.nil?

            current_headers = ::HTTP::Headers.new unless TargetIntel.same_origin?(current, next_url)
            visited << next_url
            current = next_url
            hops += 1
          end
        rescue
          ResourceFetch.new(nil, current, hops, "exception")
        end
      end

      private def resource_redirect_step(result : Http::Result, current : String, scope : String, visited : Set(String), hops : Int32) : TargetIntel::RedirectDecision
        location = result.headers["Location"]?.try(&.strip)
        return TargetIntel::RedirectDecision.stop("missing_location") if location.nil? || location.empty?

        decision = TargetIntel.redirect_target(current, location, scope)
        return decision unless decision.stop_reason.nil?

        next_url = decision.next_url
        if next_url.nil?
          decision
        elsif visited.includes?(next_url)
          TargetIntel::RedirectDecision.stop("redirect_loop")
        elsif hops >= MAX_MAIN_REDIRECTS
          TargetIntel::RedirectDecision.stop("max_redirects")
        else
          decision
        end
      end

      private def retry?(result : Http::Result) : Bool
        return true if result.error?

        status = result.status
        !status.nil? && (status == 429 || status >= 500)
      end

      private def redirect?(status : Int32?) : Bool
        !status.nil? && REDIRECT_CODES.includes?(status)
      end

      private def build_headers(base : ::HTTP::Headers, user_agent : String) : ::HTTP::Headers
        headers = ::HTTP::Headers.new
        base.each { |name, values| headers[name] = values }
        headers["User-Agent"] = user_agent
        headers
      end
    end

    # The terminal outcome of the main-page fetch. On success it carries the body
    # to parse; either way it carries the fetch profiles, the user-agent that
    # reached the page, and (on failure) the error envelope, all of which land in
    # the crawler result.
    struct FetchStatus
      getter? ok : Bool
      getter body : String?
      getter effective_url : String
      getter request_headers : ::HTTP::Headers
      getter active_user_agent : String?
      getter outcome : String
      getter profiles : FetchProfiles?
      getter canonical_handoff : String?
      getter message : String?
      getter failure_reason : String?
      getter http_status : Int32?
      getter error_class : String?

      def initialize(
        @ok : Bool,
        @effective_url : String,
        @outcome : String,
        @request_headers : ::HTTP::Headers = ::HTTP::Headers.new,
        @body : String? = nil,
        @active_user_agent : String? = nil,
        @profiles : FetchProfiles? = nil,
        @canonical_handoff : String? = nil,
        @message : String? = nil,
        @failure_reason : String? = nil,
        @http_status : Int32? = nil,
        @error_class : String? = nil,
      )
      end

      def self.invalid_target : FetchStatus
        new(ok: false, effective_url: "", outcome: "failed",
          message: "Unsafe or malformed target URL", failure_reason: "invalid_target")
      end
    end

    # Which user-agent phase the main fetch is in.
    enum Phase
      Primary
      Fallback
    end

    # The mutable main-fetch state: the active phase and user-agent, the headers
    # (dropped on an origin change), the visited set (loop guard), and the two
    # fetch profiles the state machine updates in place.
    class MainFetchState
      property phase : Phase = Phase::Primary
      property user_agent : String = USER_AGENT
      property headers : ::HTTP::Headers
      getter visited : Set(String)
      getter primary : FetchProfile
      property fallback : FetchProfile? = nil
      property? degraded : Bool = false

      def initialize(current : String, headers : ::HTTP::Headers)
        @headers = headers
        @visited = Set{current}
        @primary = FetchProfile.new(current)
      end

      def active_profile : FetchProfile
        (@phase.fallback? ? @fallback : @primary) || @primary
      end

      def profiles : FetchProfiles
        FetchProfiles.new(@primary, @fallback)
      end

      def total_hops : Int32
        @primary.hops + (@fallback.try(&.hops) || 0)
      end
    end

    # One main-fetch iteration result: a terminal status, or the next URL to
    # fetch (a followed redirect or the fallback-UA retry of the same URL).
    record Step, status : FetchStatus? = nil, next_url : String? = nil

    # The main-page fetch state machine. Fetches the scan target, falls back to a
    # browser user-agent on a bot block (403/405/429), and follows same-scope
    # redirects up to MAX_MAIN_REDIRECTS, recording the fetch profiles along the
    # way. Ports crawler/http.rb's fetch_page_status and its helpers. Complexity:
    # O(1) rounds (fixed redirect budget plus one fallback), each an O(1)-request
    # fetch.
    class MainFetch
      def initialize(@fetcher : Fetcher, @request_headers : ::HTTP::Headers)
      end

      def run(scan_target : String) : FetchStatus
        current = TargetIntel.normalize_http_url(scan_target)
        return FetchStatus.invalid_target if current.nil?

        state = MainFetchState.new(current, @request_headers)
        loop do
          step = advance(current, scan_target, state)
          status = step.status
          return status unless status.nil?

          next_url = step.next_url
          return FetchStatus.invalid_target if next_url.nil?

          current = apply_redirect(current, next_url, state)
        end
      end

      private def advance(current : String, scope_target : String, state : MainFetchState) : Step
        result = @fetcher.get(current, state.headers, state.user_agent)
        return Step.new(status: transport_failure(result, state, current)) if result.error?

        record_response(state, result, current)
        status = result.status
        return Step.new(status: success(result, state, current)) if success_status?(status)
        return Step.new(next_url: activate_fallback(state)) if state.phase.primary? && bot_block?(status)
        return Step.new(status: stopped(result, state, current)) unless redirect?(status)

        redirect_step(current, result, scope_target, state)
      end

      private def redirect_step(current : String, result : Http::Result, scope_target : String, state : MainFetchState) : Step
        status = result.status
        location = result.headers["Location"]?.try(&.strip)
        return Step.new(status: redirect_failure("missing_location", status, state, current)) if location.nil? || location.empty?

        decision = TargetIntel.redirect_target(current, location, scope_target)
        reason = decision.stop_reason
        return Step.new(status: redirect_failure(reason, status, state, current, decision.canonical_handoff)) unless reason.nil?

        next_url = decision.next_url
        return Step.new(status: redirect_failure("invalid_redirect", status, state, current)) if next_url.nil?
        return Step.new(status: redirect_failure("loop", status, state, current)) if state.visited.includes?(next_url)
        return Step.new(status: redirect_failure("max_redirects", status, state, current)) if state.total_hops >= MAX_MAIN_REDIRECTS

        Step.new(next_url: next_url)
      end

      private def record_response(state : MainFetchState, result : Http::Result, current : String) : Nil
        profile = state.active_profile
        profile.status = result.status
        location = result.headers["Location"]?.try(&.strip)
        profile.location = location if location && !location.empty?
        profile.effective_url = current
      end

      private def activate_fallback(state : MainFetchState) : String
        anchor = state.primary.effective_url
        state.phase = Phase::Fallback
        state.user_agent = FALLBACK_USER_AGENT
        state.fallback = FetchProfile.new(anchor)
        state.degraded = true
        anchor
      end

      private def apply_redirect(current : String, next_url : String, state : MainFetchState) : String
        state.headers = ::HTTP::Headers.new unless TargetIntel.same_origin?(current, next_url)
        state.visited << next_url
        state.active_profile.hops += 1 unless current == next_url
        next_url
      end

      private def success(result : Http::Result, state : MainFetchState, current : String) : FetchStatus
        FetchStatus.new(
          ok: true, body: result.body || "", effective_url: current,
          request_headers: state.headers, active_user_agent: state.user_agent,
          outcome: state.degraded? ? "degraded" : "ok", profiles: state.profiles,
        )
      end

      private def transport_failure(result : Http::Result, state : MainFetchState, current : String) : FetchStatus
        FetchStatus.new(
          ok: false, effective_url: current, outcome: "failed",
          profiles: state.profiles, active_user_agent: state.user_agent, request_headers: state.headers,
          message: diagnostic("Failed to fetch target: #{result.error_message}"),
          failure_reason: "transport_error", error_class: result.error_kind.to_s,
        )
      end

      private def stopped(result : Http::Result, state : MainFetchState, current : String) : FetchStatus
        status = result.status
        bot = bot_block?(status)
        reason = "http_status"
        reason = "refused" if bot
        reason = "rate_limited" if status == 429
        FetchStatus.new(
          ok: false, effective_url: current, outcome: bot ? "degraded" : "failed",
          profiles: state.profiles, active_user_agent: state.user_agent, request_headers: state.headers,
          message: diagnostic("HTTP status #{status}"), failure_reason: reason, http_status: status,
        )
      end

      private def redirect_failure(reason : String, status : Int32?, state : MainFetchState, current : String, handoff : String? = nil) : FetchStatus
        degraded = reason == "canonical_handoff" || reason == "loop" || reason == "max_redirects"
        FetchStatus.new(
          ok: false, effective_url: current, outcome: degraded ? "degraded" : "failed",
          profiles: state.profiles, active_user_agent: state.user_agent, request_headers: state.headers,
          canonical_handoff: handoff, message: diagnostic("Redirect stopped: #{reason.gsub('_', ' ')}"),
          failure_reason: "redirect_#{reason}", http_status: status,
        )
      end

      private def success_status?(status : Int32?) : Bool
        !status.nil? && status >= 200 && status < 300
      end

      private def bot_block?(status : Int32?) : Bool
        !status.nil? && BOT_BLOCK_CODES.includes?(status)
      end

      private def redirect?(status : Int32?) : Bool
        !status.nil? && REDIRECT_CODES.includes?(status)
      end

      # Collapses newlines and caps the length so an error line stays a single
      # bounded diagnostic. O(len).
      private def diagnostic(message : String) : String
        cleaned = message.gsub(/[\r\n]+/, " ").strip
        cleaned.size > 500 ? cleaned[0, 500] : cleaned
      end
    end
  end
end
