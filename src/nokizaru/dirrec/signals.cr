require "./limits"

module Nokizaru
  module DirRec
    # High-signal path recognition shared by confidence scoring and result
    # ranking. Ports the path-signal helpers from dirrec/results.rb. O(len) per
    # path against the fixed HIGH_SIGNAL_PATHS list.
    module Signals
      extend self

      HIGH_SIGNAL_TOKENS = HIGH_SIGNAL_PATHS.map(&.lchop("/").downcase)

      # A low-information single path segment (short, all-letters, not a prefix of
      # any high-signal token).
      LOW_INFO_SEGMENT = /\A[a-z]{1,10}\z/

      def high_signal_path?(path : String) : Bool
        HIGH_SIGNAL_PATHS.any? { |seed| path_matches_seed?(path, seed.downcase) }
      end

      def path_matches_seed?(path : String, seed : String) : Bool
        path == seed || path.starts_with?("#{seed}/")
      end

      def first_path_segment(path : String) : String
        (path.split('/').reject(&.empty?).first? || "").downcase
      end

      def low_information_segment?(segment : String) : Bool
        segment.matches?(LOW_INFO_SEGMENT) && HIGH_SIGNAL_TOKENS.none?(&.includes?(segment))
      end
    end
  end
end
