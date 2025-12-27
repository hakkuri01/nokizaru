# frozen_string_literal: true

module Nokizaru
  module Exporters
    class Txt
      def write(run, path)
        File.open(path, 'w') do |f|
          meta = run.fetch('meta', {})
          f.puts("Target: #{meta['target']}") if meta['target']
          f.puts("Started: #{meta['started_at']}") if meta['started_at']
          f.puts("Ended: #{meta['ended_at']}") if meta['ended_at']
          f.puts

          findings = Array(run['findings'])
          if findings.any?
            f.puts('Findings')
            f.puts('========')
            findings.each do |fi|
              f.puts("[#{(fi['severity'] || 'low').upcase}] #{fi['title']}")
              f.puts("  Evidence: #{fi['evidence']}") if fi['evidence']
              f.puts("  Recommendation: #{fi['recommendation']}") if fi['recommendation']
              f.puts
            end
            f.puts
          end

          modules = run.fetch('modules', {})
          modules.each do |name, payload|
            f.puts(name)
            f.puts('=' * name.length)
            f.puts(payload.is_a?(String) ? payload : payload.inspect)
            f.puts
          end

          if run['diff'] && run['diff'].any?
            f.puts('Diff')
            f.puts('====')
            run['diff'].each do |k, v|
              f.puts("#{k} (+#{Array(v['added']).length} / -#{Array(v['removed']).length})")
              f.puts('  ADDED:')
              Array(v['added']).each { |x| f.puts("    #{x}") }
              f.puts('  REMOVED:')
              Array(v['removed']).each { |x| f.puts("    #{x}") }
              f.puts
            end
          end
        end
      end
    end
  end
end
