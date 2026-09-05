# frozen_string_literal: true

require 'erb'
require 'cgi'
require_relative 'html_template'

module Nokizaru
  module Exporters
    class Html
      TEMPLATE = HtmlTemplate::TEMPLATE

      def write(run, path)
        meta = run.fetch('meta', {})
        findings = Array(run['findings'])
        modules = run.fetch('modules', {})

        renderer = ERB.new(TEMPLATE)
        html = renderer.result(binding)
        File.write(path, html)
      end

      private

      def h(str)
        CGI.escapeHTML(str.to_s)
      end

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
