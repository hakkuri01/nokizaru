# frozen_string_literal: true

module Nokizaru
  module Exporters
    # Nokizaru::Exporters::Txt implementation
    class Txt
      # Append log entries with timestamps for troubleshooting and auditability
      def write(run, path)
        File.open(path, 'w') { |file| write_sections(file, run) }
      end

      def write_sections(file, run)
        write_meta(file, run.fetch('meta', {}))
        write_findings(file, Array(run['findings']))
        write_modules(file, run.fetch('modules', {}))
        write_diff(file, run['diff'])
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

      def write_diff(file, diff)
        return unless diff&.any?

        file.puts('Diff')
        file.puts('====')
        diff.each { |kind, values| write_diff_block(file, kind, values) }
      end

      def write_diff_block(file, kind, values)
        file.puts("#{kind} (+#{Array(values['added']).length} / -#{Array(values['removed']).length})")
        write_diff_values(file, 'ADDED', values['added'])
        write_diff_values(file, 'REMOVED', values['removed'])
        file.puts
      end

      def write_diff_values(file, label, entries)
        file.puts("  #{label}:")
        Array(entries).each { |entry| file.puts("    #{entry}") }
      end
    end
  end
end
