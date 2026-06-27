# frozen_string_literal: true

module Nokizaru
  module Modules
    module ArchitectureFingerprinting
      # Console output helpers for architecture results
      module Presenter
        module_function

        def print(technologies)
          return print_empty unless technologies.any?

          UI.section('Architecture Fingerprinting Results :')
          UI.with_terminal_output { technologies.first(20).each { |entry| $stdout.puts(entry_line(entry)) } }
          UI.line(:info, 'Results truncated...') if technologies.length > 20
          UI.blank_line
          UI.row(:info, 'Total Unique Technologies Found', technologies.length)
        end

        def print_empty
          UI.line(:error, 'No technologies identified')
        end

        def entry_line(entry)
          details = []
          version = entry['version'].to_s
          categories = Array(entry['categories'])
          details << "version: #{version}" unless version.empty?
          details << "categories: #{categories.join(', ')}" if categories.any?
          suffix = details.empty? ? '' : " (#{details.join(' | ')})"
          "#{entry['name']}#{suffix}"
        end
      end
    end
  end
end
