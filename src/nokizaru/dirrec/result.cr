require "json"

module Nokizaru
  module DirRec
    # The anchoring summary for the enumerated target. Matches the Ruby
    # dir_result["target"] hash (no reason_code, unlike the crawler).
    struct Target
      include JSON::Serializable

      getter original : String
      getter effective : String
      getter? reanchored : Bool
      getter reason : String

      def initialize(@original : String, @effective : String, @reanchored : Bool, @reason : String)
      end
    end

    # The directory-scan stats. Field order and names match the Ruby dir_stats
    # hash so the benchmark harness can diff it. Runtime adaptation fills its
    # counters live; final confidence reconciliation fills the finding counters.
    class Stats
      include JSON::Serializable

      property mode : String = "full"

      @[JSON::Field(emit_null: true)]
      property stop_reason : String? = nil

      @[JSON::Field(emit_null: true)]
      property stop_reason_display : String? = nil

      property? adversary_persisted : Bool = false

      @[JSON::Field(emit_null: true)]
      property adversary_adaptation : String? = nil

      property budget_seconds : Float64 = 0.0
      property max_requests : Int32 = 0

      @[JSON::Field(emit_null: true)]
      property preflight : String? = nil

      property total_requests : Int32 = 0
      property successful : Int32 = 0
      property errors : Int32 = 0
      property error_breakdown : Hash(String, Int32) = {} of String => Int32
      property timeout_downshifts : Int32 = 0
      property mode_downshifts : Int32 = 0
      property pressure_events : Int32 = 0
      property low_yield_events : Int32 = 0
      property elapsed_seconds : Float64 = 0.0
      property requests_per_second : Float64 = 0.0
      property? extension_phase_enabled : Bool = false

      @[JSON::Field(emit_null: true)]
      property extension_phase_reason : String? = nil

      property dispatch_mode : String = "fiber_pool"
      property? dispatch_http2_confirmed : Bool = false
      property dispatch_fallback_reason : String = ""

      @[JSON::Field(emit_null: true)]
      property stop_status_code_shape : String? = nil

      property adaptive_concurrency : Int32 = 0
      property time_to_first_actionable_s : Float64 = 0.0
      property requests_to_first_actionable : Int32 = 0
      property pressure_streak : Int32 = 0
      property low_yield_streak : Int32 = 0
      property pressure_score : Int32 = 0
      property pressure_window_avg_rps : Float64 = 0.0
      property pressure_window_error_ratio : Float64 = 0.0
      property pressure_window_transport_ratio : Float64 = 0.0
      property pressure_window_prioritized_gain : Int32 = 0
      property confidence_levels : Hash(String, Int32) = {} of String => Int32
      property confidence_reasons : Hash(String, Int32) = {} of String => Int32
      property waf_sensitive_promotion_count : Int32 = 0
      property waf_likelihood_score : Float64 = 0.0
      property waf_score_confidence : String = "low"
      property redirect_cluster_dominance_ratio : Float64 = 0.0
      property soft_404_dominance_ratio : Float64 = 0.0
      property sensitive_status_total : Int32 = 0
      property sensitive_status_homogeneity_ratio : Float64 = 0.0
      property sensitive_status_fingerprint_uniqueness_ratio : Float64 = 0.0
      property context_sources_used : Array(String) = [] of String
      property context_sources_missing : Array(String) = [] of String

      def initialize
      end
    end

    # The directory enumeration result. Field order matches the Ruby dir_result.
    class Result
      include JSON::Serializable

      property target : Target
      property found : Array(String) = [] of String
      property prioritized_found : Array(String) = [] of String
      property stdout_found : Array(String) = [] of String
      property confirmed_found : Array(String) = [] of String
      property low_confidence_found : Array(String) = [] of String
      property high_signal_found : Array(String) = [] of String
      property by_status : Hash(String, Array(String)) = {} of String => Array(String)
      property stats : Stats = Stats.new

      def initialize(@target : Target)
      end
    end
  end
end
