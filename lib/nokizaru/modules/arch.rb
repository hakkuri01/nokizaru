# frozen_string_literal: true

require_relative '../http_client'
require_relative '../log'
require_relative '../keys'
require_relative 'arch/client'
require_relative 'arch/parser'
require_relative 'arch/presenter'

module Nokizaru
  module Modules
    # Architecture fingerprinting orchestration module
    module ArchitectureFingerprinting
      module_function

      DEFAULT_UA = "Nokizaru/#{Nokizaru::VERSION} (+https://github.com/hakkuri01)".freeze

      def call(target, timeout, ctx, _conf_path)
        UI.module_header('Starting Architecture Fingerprinting...')
        api_key = KeyStore.fetch('wappalyzer', env: 'NK_WAPPALYZER_KEY')
        return mark_skipped(ctx) if api_key.to_s.strip.empty?

        technologies = collect_technologies(target, timeout, api_key)
        Presenter.print(technologies)
        persist_result(ctx, technologies)
      rescue StandardError => e
        handle_exception(ctx, e)
      end

      def collect_technologies(target, timeout, api_key)
        body = Client.fetch(http_client(timeout), target, api_key)
        return [] if body.empty?

        Parser.parse(body)
      end

      def http_client(timeout)
        Nokizaru::HTTPClient.build(
          timeout_s: [timeout.to_f, 12.0].min,
          headers: { 'User-Agent' => DEFAULT_UA },
          follow_redirects: true,
          persistent: true,
          verify_ssl: true
        )
      end

      def mark_skipped(ctx)
        UI.row(:error, 'Skipping Architecture Fingerprinting', 'API key not found!')
        Log.write('[arch] API key not found')
        ctx.run['modules']['architecture_fingerprinting'] = { 'technologies' => [], 'status' => 'skipped_no_key' }
      end

      def persist_result(ctx, technologies)
        ctx.run['modules']['architecture_fingerprinting'] = {
          'technologies' => technologies,
          'status' => 'ok'
        }
        ctx.add_artifact('technologies', technologies.map { |entry| entry['name'] }.compact)
        Log.write('[arch] Completed')
      end

      def handle_exception(ctx, error)
        UI.line(:error, "Architecture Fingerprinting Exception : #{error}")
        Log.write("[arch] Exception = #{error}")
        ctx.run['modules']['architecture_fingerprinting'] = { 'technologies' => [], 'status' => 'error' }
      end
    end
  end
end
