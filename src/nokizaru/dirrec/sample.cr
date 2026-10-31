module Nokizaru
  module DirRec
    # A compact, fixed-size summary of one response, the unit soft-404 learning
    # and confidence scoring work on. Content samples carry content_type,
    # body_length, title, and fingerprint; redirect samples carry location and
    # redirect_pattern. Never holds the body.
    struct Sample
      getter status : Int32
      getter content_type : String?
      getter body_length : Int32
      getter title : String?
      getter fingerprint : String?
      getter location : String?
      getter redirect_pattern : String?

      def initialize(
        @status : Int32,
        @content_type : String? = nil,
        @body_length : Int32 = 0,
        @title : String? = nil,
        @fingerprint : String? = nil,
        @location : String? = nil,
        @redirect_pattern : String? = nil,
      )
      end
    end

    # The learned soft-404 signature a response is matched against. For a content
    # baseline: status + content_type + body_length (+ tolerance/title/fingerprint).
    # For a redirect baseline: status + redirect_pattern or location.
    struct Baseline
      getter status : Int32
      getter content_type : String?
      getter body_length : Int32?
      getter tolerance : Int32?
      getter title : String?
      getter fingerprint : String?
      getter location : String?
      getter redirect_pattern : String?

      def initialize(
        @status : Int32,
        @content_type : String? = nil,
        @body_length : Int32? = nil,
        @tolerance : Int32? = nil,
        @title : String? = nil,
        @fingerprint : String? = nil,
        @location : String? = nil,
        @redirect_pattern : String? = nil,
      )
      end
    end
  end
end
