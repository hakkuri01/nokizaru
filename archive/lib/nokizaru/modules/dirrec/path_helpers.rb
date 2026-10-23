# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module PathHelpers
        private

        def join_url(base, path)
          cleaned = path.to_s.strip
          cleaned = "/#{cleaned}" unless cleaned.start_with?('/')
          "#{base.to_s.strip.chomp('/')}#{cleaned}"
        end

        def encode_path_word(word)
          word.to_s.split('/').map { |segment| percent_encode_path_segment(segment) }.join('/')
        end

        # Encode path segments safely without converting spaces to plus signs
        def percent_encode_path_segment(segment)
          bytes = segment.to_s.b.bytes
          bytes.map do |byte|
            char = byte.chr
            if char.match?(/[A-Za-z0-9\-._~]/)
              char
            else
              format('%%%02X', byte)
            end
          end.join
        end
      end
    end
  end
end
