# frozen_string_literal: true

require 'erb'
require 'cgi'
require_relative 'html_template'

module Nokizaru
  module Exporters
    # Nokizaru::Exporters::Html implementation
    class Html
      TEMPLATE = HtmlTemplate::TEMPLATE

      # Append log entries with timestamps for troubleshooting and auditability
      def write(run, path)
        meta = run.fetch('meta', {})
        findings = Array(run['findings'])
        modules = run.fetch('modules', {})
        diff = run['diff']

        renderer = ERB.new(TEMPLATE)
        html = renderer.result(binding)
        File.write(path, html)
      end

      private

      # Escape HTML content before embedding it in generated reports
      def h(str)
        CGI.escapeHTML(str.to_s)
      end

      # Pretty print JSON for readable HTML sections
      def pretty(obj)
        case obj
        when String
          obj
        else
          require 'json'
          JSON.pretty_generate(obj)
        end
      rescue StandardError
        obj.to_s
      end
    end
  end
end
