# frozen_string_literal: true

module Nokizaru
  module Exporters
    class Txt
      def write(run, path)
        File.open(path, 'w') { |file| write_sections(file, run) }
      end

      def write_sections(file, run)
        write_meta(file, run.fetch('meta', {}))
        write_findings(file, Array(run['findings']))
        write_modules(file, run.fetch('modules', {}))
      end

      def write_meta(file, meta)
        file.puts("Target: #{meta['target']}") if meta['target']
        file.puts("Started: #{meta['started_at']}") if meta['started_at']
        file.puts("Ended: #{meta['ended_at']}") if meta['ended_at']
        file.puts
      end

      def write_findings(file, findings)
        return if findings.empty?

        file.puts('Findings')
        file.puts('========')
        findings.each { |finding| write_finding(file, finding) }
        file.puts
      end

      def write_finding(file, finding)
        file.puts("[#{(finding['severity'] || 'low').upcase}] #{finding['title']}")
        file.puts("  Evidence: #{finding['evidence']}") if finding['evidence']
        file.puts("  Recommendation: #{finding['recommendation']}") if finding['recommendation']
        file.puts
      end

      def write_modules(file, modules)
        modules.each do |name, payload|
          file.puts(name)
          file.puts('=' * name.length)
          file.puts(payload.is_a?(String) ? payload : payload.inspect)
          file.puts
        end
      end
    end
  end
end
