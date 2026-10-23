require "json"
require "../paths"
require "../run_state"

module Nokizaru
  module Exporters
    # The JSON exporter is the parity contract: it serializes the typed run tree
    # verbatim, so the bench harness can diff its output against the Ruby tool's
    # `JSON.pretty_generate(run)`. The file is written owner-only (it can hold
    # private scan data).
    module Json
      extend self

      def write(run : RunState, path : String) : Nil
        File.write(path, run.to_pretty_json, perm: Paths::PRIVATE_FILE)
      end
    end
  end
end
