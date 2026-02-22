# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Findings and terminal reporting helpers
      module Findings
        private

        def compute_findings!(run)
          run['findings'] = Nokizaru::Findings::Engine.new.run(run)
          print_findings(run['findings'])
        rescue StandardError => e
          Log.write("[findings] Exception = #{e.class}: #{e}")
          run['findings'] = []
        end

        def print_findings(findings)
          findings = Array(findings)
          return if findings.empty?

          UI.module_header('Findings')
          findings.each do |finding|
            severity = (finding['severity'] || 'low').to_s.upcase
            title = finding['title'] || 'Finding'
            mod = finding['module'] ? " (#{finding['module']})" : ''
            UI.line(:info, "#{colorize_finding_severity(severity)} #{title}#{mod}")
            UI.tree_rows([['Evidence', finding['evidence']]]) if finding['evidence']
          end
        end

        def colorize_finding_severity(severity)
          color = case severity.to_s.upcase
                  when 'CRITICAL', 'HIGH' then UI::R
                  when 'MEDIUM' then UI::Y
                  else UI::G
                  end
          "#{UI::W}⟦ #{color}#{severity.to_s.upcase}#{UI::W} ⟧"
        end

        def print_db_diff(diff_db, label:)
          diff_db = {} unless diff_db.is_a?(Hash)
          return if diff_db.empty?

          UI.line(:info, "#{label}:")
          diff_db.each do |kind, change|
            added = Array(change['added']).length
            removed = Array(change['removed']).length
            UI.row(:info, kind.to_s, "+#{added} / -#{removed}")
          end
        end
      end
    end
  end
end
