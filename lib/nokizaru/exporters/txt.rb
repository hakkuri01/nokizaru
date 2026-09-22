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
          if name == 'wayback' && payload.is_a?(Hash)
            write_wayback(file, payload)
          else
            file.puts(payload.is_a?(String) ? payload : payload.inspect)
          end
          file.puts
        end
      end

      def write_wayback(file, payload)
        file.puts("Archive Status: #{payload['archive_status'] || payload['status']}")
        file.puts("Module Status: #{payload['status']}") if payload['status']
        file.puts("Error: #{payload['error']}") if payload['error']
        write_wayback_sources(file, payload.fetch('source_health', {}))
        write_wayback_categories(file, payload)
        write_wayback_records(file, Array(payload['url_records']))
        write_wayback_urls(file, Array(payload['urls']))
        write_wayback_pivots(file, payload['manual_pivots'])
      end

      def write_wayback_categories(file, payload)
        categories = %w[
          review_urls javascript_urls api_urls interesting_path_urls interesting_parameter_urls sensitive_file_urls
        ]
        categories.each do |key|
          urls = Array(payload[key])
          next if urls.empty?

          file.puts("#{key.delete_suffix('_urls').tr('_', ' ').capitalize} (#{urls.length})")
          urls.each { |url| file.puts("  #{url}") }
        end
        counts = payload.fetch('parameter_counts', {})
        file.puts("Parameters: #{counts.map { |name, count| "#{name}=#{count}" }.join(', ')}") unless counts.empty?
      end

      def write_wayback_sources(file, sources)
        return if sources.empty?

        file.puts('Sources')
        sources.sort.each do |name, health|
          details = [health['status'], health['reason'], "records=#{health['records']}"].compact.reject(&:empty?)
          file.puts("  #{name}: #{details.join(' ')}")
        end
      end

      def write_wayback_records(file, records)
        return if records.empty?

        file.puts("Provenance (#{records.length})")
        records.each do |record|
          sources = Array(record['sources']).join(',')
          sources = record['source'].to_s if sources.empty?
          file.puts("  #{sources}\t#{record['url']}")
        end
      end

      def write_wayback_urls(file, urls)
        return if urls.empty?

        file.puts("Raw URLs (#{urls.length})")
        urls.each { |url| file.puts("  #{url}") }
      end

      def write_wayback_pivots(file, pivots)
        return unless pivots.is_a?(Hash) && !pivots.empty?

        file.puts('Manual Pivots')
        pivots.sort.each { |name, url| file.puts("  #{name}: #{url}") }
      end
    end
  end
end
