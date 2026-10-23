require "uri"
require "socket"
require "json"
require "./psl/list"
require "./http/result"

module Nokizaru
  # Target URL and scope intelligence, backed by the embedded PSL. Ports the pure
  # URL/scope helpers of the Ruby TargetIntel (registrable domain, scope, origin,
  # redirect resolution) plus the lightweight target profile modules use for
  # context-aware anchoring. The scan context injects `same_scope_host?` into the
  # HTTP pool as its redirect scope predicate, so a redirect is followed only
  # within the target's registrable domain.
  module TargetIntel
    extend self

    # A target's redirect behavior, recorded for context-aware anchoring. Shape
    # and field names match the Ruby profile hash (location stays null when there
    # is no redirect, so the key is always present).
    class Profile
      include JSON::Serializable

      property original_url : String
      property effective_url : String
      property mode : String
      property confidence : String
      property reason : String

      @[JSON::Field(emit_null: true)]
      property location : String?

      def initialize(
        @original_url : String,
        @effective_url : String,
        @mode : String,
        @confidence : String,
        @reason : String,
        @location : String? = nil,
      )
      end
    end

    # A redirect resolution outcome: either the next URL to follow, or a stop
    # with a reason (and a canonical_handoff target when the Location leaves
    # scope). Ports the Ruby `redirect_target` hash to a typed value.
    struct RedirectDecision
      getter next_url : String?
      getter stop_reason : String?
      getter canonical_handoff : String?

      def initialize(@next_url : String? = nil, @stop_reason : String? = nil, @canonical_handoff : String? = nil)
      end

      def self.follow(next_url : String) : RedirectDecision
        new(next_url: next_url)
      end

      def self.stop(reason : String) : RedirectDecision
        new(stop_reason: reason)
      end

      def self.handoff(target : String) : RedirectDecision
        new(stop_reason: "canonical_handoff", canonical_handoff: target)
      end
    end

    # The anchoring decision for a scan: whether to re-anchor to the profiled
    # effective URL, the target to actually scan, and the reason classification.
    # Ports the Ruby `decision_payload` hash.
    struct ReanchorDecision
      getter? reanchor : Bool
      getter effective_target : String
      getter reason_code : String
      getter reason : String

      def initialize(@reanchor : Bool, @effective_target : String, @reason_code : String, @reason : String)
      end
    end

    def registrable_domain(host : String) : String?
      PSL::List.default.registrable_domain(host)
    end

    def ip_address?(host : String) : Bool
      Socket::IPAddress.new(host, 0)
      true
    rescue Socket::Error
      false
    end

    # Two hosts are in scope when they share a registrable domain, so a redirect
    # from www.example.com to example.com stays in scope but a hop to an
    # unrelated domain does not. IP hosts are in scope only when identical.
    def same_scope_host?(left_host : String, right_host : String) : Bool
      left = left_host.strip.downcase
      right = right_host.strip.downcase
      return false if left.empty? || right.empty?
      return true if left == right
      return false if ip_address?(left) || ip_address?(right)

      left_registrable = registrable_domain(left)
      !left_registrable.nil? && left_registrable == registrable_domain(right)
    end

    # The redirect scope predicate wired into Http::Pool#scope_check.
    def scope_check : Proc(String, String, Bool)
      ->(left : String, right : String) { same_scope_host?(left, right) }
    end

    def resolve_location(request_url : String, location : String) : String
      URI.parse(request_url).resolve(location).to_s
    rescue
      location
    end

    def same_origin?(left_url : String, right_url : String) : Bool
      left = URI.parse(left_url)
      right = URI.parse(right_url)
      left.scheme == right.scheme && left.host == right.host &&
        effective_port(left) == effective_port(right)
    rescue
      false
    end

    # Builds the redirect profile from a response already fetched by the caller
    # (no second request), classifying a Location as an HTTP->HTTPS upgrade, a
    # same-scope redirect, or a cross-scope handoff. A response with no Location,
    # or a failed fetch, yields the default "no redirect" profile.
    def profile(target : String, result : Http::Result?) : Profile
      prof = default_profile(target)
      return prof if result.nil? || result.error?

      location = result.headers["Location"]?.try(&.strip)
      return prof if location.nil? || location.empty?

      resolved = resolve_location(target, location)
      prof.location = resolved
      classify_redirect(prof, URI.parse(target), URI.parse(resolved), target)
      prof
    rescue
      failed_profile(target)
    end

    # Canonicalizes an HTTP(S) URL for safe comparison: lowercases scheme and
    # host, drops the fragment, defaults an empty path to "/", and drops a
    # default port. Rejects non-HTTP(S) URLs, those without a host, and those
    # carrying userinfo (a redirect to user:pass@host is a known phishing shape).
    # ponytail: no full RFC 3986 path/percent normalization (Ruby leaned on
    # URI#normalize); the lowercase+default-port form covers the comparisons the
    # redirect and scope checks need, and the input is a single URL so the pass
    # is O(len). Returns nil when the URL is not a safe HTTP(S) target.
    def normalize_http_url(url : String) : String?
      uri = URI.parse(url)
      raw_scheme = uri.scheme
      return nil if raw_scheme.nil?

      scheme = raw_scheme.downcase
      return nil unless scheme == "http" || scheme == "https"

      host = uri.host
      return nil if host.nil? || host.empty?
      return nil unless uri.user.nil?

      build_normalized(scheme, host.downcase, uri)
    rescue
      nil
    end

    private def build_normalized(scheme : String, host : String, uri : URI) : String
      path = uri.path
      path = "/" if path.empty?
      port = uri.port
      port = nil if port == default_port(scheme)
      String.build do |io|
        io << scheme << "://" << host
        io << ":" << port if port
        io << path
        query = uri.query
        io << "?" << query if query && !query.empty?
      end
    end

    # Resolves a Location against the request URL and classifies the hop: a safe
    # same-scope next URL, an out-of-scope canonical handoff, an HTTPS->HTTP
    # downgrade (unsafe), or an unparseable target (invalid). Mirrors the Ruby
    # `redirect_target`; `scope_url` bounds what counts as in-scope (defaults to
    # the request URL). O(len) over the URLs.
    def redirect_target(request_url : String, location : String, scope_url : String = request_url) : RedirectDecision
      target = normalize_http_url(resolve_location(request_url, location))
      return RedirectDecision.stop("invalid_redirect") if target.nil?

      source_norm = normalize_http_url(request_url)
      scope_norm = normalize_http_url(scope_url)
      return RedirectDecision.stop("invalid_redirect") if source_norm.nil? || scope_norm.nil?

      source = URI.parse(source_norm)
      destination = URI.parse(target)
      return RedirectDecision.stop("unsafe_redirect") if source.scheme == "https" && destination.scheme == "http"

      scope = URI.parse(scope_norm)
      return RedirectDecision.handoff(target) unless same_scope_host?(scope.host || "", destination.host || "")

      RedirectDecision.follow(target)
    rescue
      RedirectDecision.stop("invalid_redirect")
    end

    # Decides whether a scan should re-anchor from the requested target to the
    # profiled effective URL. A high-confidence HTTP->HTTPS upgrade always
    # re-anchors; a medium-confidence canonical same-scope redirect re-anchors
    # only when scheme and path line up and the host actually changed. Ports the
    # Ruby `reanchor_decision`.
    def reanchor_decision(target : String, profile : Profile) : ReanchorDecision
      effective = profile.effective_url
      reanchor = (profile.mode == "http_to_https" && profile.confidence == "high" && !effective.empty?) ||
                 canonical_same_scope_reanchor?(target, effective, profile.mode, profile.confidence)
      effective_target = reanchor ? effective : target
      ReanchorDecision.new(reanchor, effective_target, reason_code_for(profile), profile.reason)
    end

    private def canonical_same_scope_reanchor?(target : String, effective : String, mode : String, confidence : String) : Bool
      return false unless mode == "same_scope_redirect" && confidence == "medium"

      source = URI.parse(target)
      destination = URI.parse(effective)
      source_host = source.host || ""
      destination_host = destination.host || ""
      source.scheme == destination.scheme &&
        canonical_redirect_path?(source, destination) &&
        source_host.downcase != destination_host.downcase &&
        same_scope_host?(source_host, destination_host)
    rescue
      false
    end

    # Maps a redirect profile to the short reason code the crawler and dirrec
    # modules record alongside their re-anchor decision. Ports `reason_code_for`.
    def reason_code_for(profile : Profile) : String
      case profile.mode
      when "http_to_https"        then "http->https"
      when "same_scope_redirect"  then "same-scope"
      when "cross_scope_redirect" then "cross-scope"
      else
        profile.reason.downcase.includes?("failed") ? "profile-failed" : "no-redirect"
      end
    end

    private def default_profile(target : String) : Profile
      Profile.new(target, target, "none", "low", "No stable redirect behavior detected")
    end

    private def failed_profile(target : String) : Profile
      profile = default_profile(target)
      profile.reason = "Target profiling failed"
      profile
    end

    private def classify_redirect(prof : Profile, source : URI, destination : URI, target : String) : Nil
      if http_to_https_upgrade?(source, destination)
        prof.mode = "http_to_https"
        prof.confidence = "high"
        prof.reason = "Canonical HTTP to HTTPS redirect detected"
        prof.effective_url = canonical_url_for(target, destination)
      elsif same_scope_host?(source.host || "", destination.host || "")
        prof.mode = "same_scope_redirect"
        prof.confidence = canonical_redirect_path?(source, destination) ? "medium" : "low"
        prof.reason = "Redirect detected within the same target scope"
        prof.effective_url = canonical_url_for(target, destination)
      else
        prof.mode = "cross_scope_redirect"
        prof.confidence = "low"
        prof.reason = "Redirect target is outside original scope"
      end
    end

    private def http_to_https_upgrade?(source : URI, destination : URI) : Bool
      source.scheme == "http" && destination.scheme == "https" &&
        same_scope_host?(source.host || "", destination.host || "")
    end

    private def canonical_redirect_path?(source : URI, destination : URI) : Bool
      path = normalize_path(destination.path)
      path == "/" || path == normalize_path(source.path)
    end

    private def canonical_url_for(original_target : String, canonical : URI) : String
      original = URI.parse(original_target)
      base = "#{canonical.scheme}://#{canonical.host}"
      port = canonical.port
      base += ":#{port}" if port && port != default_port(canonical.scheme)
      full = "#{base}#{normalize_path(original.path)}"
      query = original.query
      query && !query.empty? ? "#{full}?#{query}" : full
    end

    private def normalize_path(path : String) : String
      path.empty? ? "/" : path
    end

    private def effective_port(uri : URI) : Int32?
      uri.port || default_port(uri.scheme)
    end

    private def default_port(scheme : String?) : Int32?
      case scheme
      when "https" then 443
      when "http"  then 80
      end
    end
  end
end
