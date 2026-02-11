# frozen_string_literal: true

require 'json'
require_relative '../http_client'
require_relative '../log'
require_relative '../keys'

module Nokizaru
  module Modules
    module ArchitectureFingerprinting
      module_function

      DEFAULT_UA = "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)"

      # Run this module and store normalized results in the run context
      def call(target, timeout, ctx, _conf_path)
        UI.module_header('Starting Architecture Fingerprinting...')

        api_key = KeyStore.fetch('wappalyzer', env: 'NK_WAPPALYZER_KEY')
        if api_key.to_s.strip.empty?
          UI.row(:error, 'Skipping Architecture Fingerprinting', 'API key not found!')
          Log.write('[arch] API key not found')
          ctx.run['modules']['architecture_fingerprinting'] = { 'technologies' => [], 'status' => 'skipped_no_key' }
          return
        end

        http = Nokizaru::HTTPClient.build(
          timeout_s: [timeout.to_f, 12.0].min,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: true,
          persistent: true,
          verify_ssl: true
        )

        tech = fetch_technologies(http, target, api_key)
        print_technologies(tech)

        ctx.run['modules']['architecture_fingerprinting'] = {
          'technologies' => tech,
          'status' => 'ok'
        }
        ctx.add_artifact('technologies', tech.map { |t| t['name'] }.compact)
        Log.write('[arch] Completed')
      rescue StandardError => e
        UI.line(:error, "Architecture Fingerprinting Exception : #{e}")
        Log.write("[arch] Exception = #{e}")
        ctx.run['modules']['architecture_fingerprinting'] = { 'technologies' => [], 'status' => 'error' }
      end

      # Fetch detection data used for architecture fingerprinting output
      def fetch_technologies(http, target, api_key)
        url = 'https://api.wappalyzer.com/v2/lookup/'
        headers = { 'x-api-key' => api_key }
        resp = http.get(url, headers: headers, params: { urls: target })

        status = resp&.status
        unless status == 200
          reason = if resp.respond_to?(:error) && resp.error
                     resp.error.to_s
                   else
                     "status=#{status || 'ERR'}"
                   end
          UI.line(:error,
                  "Architecture Fingerprinting Status : #{status || 'ERR'}#{reason.empty? ? '' : " (#{reason})"}")
          Log.write("[arch] Status = #{status.inspect}, expected 200")
          return []
        end

        parse_wappalyzer_body(resp.body.to_s)
      rescue StandardError => e
        UI.line(:error, "Architecture Fingerprinting Parse Exception : #{e}")
        Log.write("[arch] Parse exception = #{e}")
        []
      end

      # Parse Wappalyzer response payload into technology candidates
      def parse_wappalyzer_body(body)
        data = JSON.parse(body)
        rows = data.is_a?(Array) ? data : [data]

        tech = rows.flat_map do |row|
          Array(row['technologies']).map do |entry|
            {
              'name' => entry['name'].to_s,
              'version' => entry['version'].to_s,
              'categories' => Array(entry['categories']).map do |c|
                c.is_a?(Hash) ? c['name'].to_s : c.to_s
              end.reject(&:empty?)
            }
          end
        end

        dedupe_technologies(tech)
      end

      # Deduplicate technologies while keeping stable output ordering
      def dedupe_technologies(tech)
        out = {}

        Array(tech).each do |entry|
          name = entry['name'].to_s.strip
          next if name.empty?

          key = name.downcase
          existing = out[key]
          if existing
            existing['categories'] = (Array(existing['categories']) + Array(entry['categories'])).reject(&:empty?).uniq
            existing['version'] = entry['version'] if existing['version'].to_s.empty? && !entry['version'].to_s.empty?
          else
            out[key] = {
              'name' => name,
              'version' => entry['version'].to_s,
              'categories' => Array(entry['categories']).reject(&:empty?).uniq
            }
          end
        end

        out.values.sort_by { |e| e['name'].downcase }
      end

      # Print detected technologies in a concise terminal format
      def print_technologies(tech)
        if tech.empty?
          UI.line(:error, 'No technologies identified')
          return
        end

        UI.section('Architecture Fingerprinting Results :')
        tech.first(20).each do |entry|
          categories = Array(entry['categories'])
          version = entry['version'].to_s
          details = []
          details << "version: #{version}" unless version.empty?
          details << "categories: #{categories.join(', ')}" if categories.any?
          suffix = details.empty? ? '' : " (#{details.join(' | ')})"
          puts("#{entry['name']}#{suffix}")
        end
        UI.line(:info, 'Results truncated...') if tech.length > 20
        puts
        UI.row(:info, 'Total Unique Technologies Found', tech.length)
      end
    end
  end
end
