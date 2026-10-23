require "ecr"
require "html"
require "json"
require "../paths"
require "../run_state"

module Nokizaru
  module Exporters
    # The HTML exporter renders the typed run into a compiled ECR template. meta
    # and findings are read as typed fields; the free-form per-module payloads are
    # serialized once from the typed `modules` object and dumped as pretty JSON in
    # a collapsible block, as the Ruby tool did. The file is owner-only.
    module Html
      extend self

      def write(run : RunState, path : String) : Nil
        File.write(path, Report.new(run).to_s, perm: Paths::PRIVATE_FILE)
      end

      # Holds the data the template reads and the two display helpers it calls.
      # meta and findings are read as typed fields. The free-form module payloads
      # are serialized once from the typed `modules` object for display iteration
      # (the typed model is unchanged; the template never decodes back into it).
      # Complexity: one O(n) encode over the bounded, once-per-scan export payload,
      # off every hot path; the json contract exporter pays no such round-trip.
      struct Report
        def initialize(run : RunState)
          @meta = run.meta
          @findings = run.findings
          @modules = ::JSON.parse(run.modules.to_json).as_h
        end

        private def h(value) : String
          ::HTML.escape(value.to_s)
        end

        private def pretty(payload : ::JSON::Any) : String
          string = payload.as_s?
          return string if string

          payload.to_pretty_json
        end

        ECR.def_to_s "#{__DIR__}/report.ecr"
      end
    end
  end
end
