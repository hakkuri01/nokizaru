# frozen_string_literal: true

require 'json'

module Nokizaru
  module Exporters
    class Json
      # Append log entries with timestamps for troubleshooting and auditability
      def write(run, path)
        File.write(path, JSON.pretty_generate(run))
      end
    end
  end
end
