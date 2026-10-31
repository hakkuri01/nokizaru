module Nokizaru
  module DirRec
    # URL and path-segment construction for candidate URLs. Percent-encoding is
    # done per byte so a space never becomes "+" (which a server would treat as
    # a different path). O(len).
    module PathHelpers
      extend self

      def join_url(base : String, path : String) : String
        cleaned = path.strip
        cleaned = "/#{cleaned}" unless cleaned.starts_with?("/")
        "#{base.strip.rchop("/")}#{cleaned}"
      end

      def encode_path_word(word : String) : String
        word.split('/').map { |segment| percent_encode_path_segment(segment) }.join('/')
      end

      def percent_encode_path_segment(segment : String) : String
        String.build do |io|
          segment.each_byte do |byte|
            char = byte.unsafe_chr
            if char.ascii_alphanumeric? || "-._~".includes?(char)
              io << char
            else
              io << '%' << byte.to_s(16).rjust(2, '0').upcase
            end
          end
        end
      end
    end
  end
end
