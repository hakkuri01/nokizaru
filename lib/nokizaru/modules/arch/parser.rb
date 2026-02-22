# frozen_string_literal: true

require 'json'

module Nokizaru
  module Modules
    module ArchitectureFingerprinting
      # Response parser and deduper for architecture results
      module Parser
        module_function

        def parse(body)
          data = JSON.parse(body)
          rows = data.is_a?(Array) ? data : [data]
          technologies = rows.flat_map { |row| row_technologies(row) }
          dedupe(technologies)
        end

        def row_technologies(row)
          Array(row['technologies']).map { |entry| normalized_technology(entry) }
        end

        def normalized_technology(entry)
          {
            'name' => entry['name'].to_s,
            'version' => entry['version'].to_s,
            'categories' => normalized_categories(entry['categories'])
          }
        end

        def normalized_categories(categories)
          Array(categories).map { |value| value.is_a?(Hash) ? value['name'].to_s : value.to_s }.reject(&:empty?)
        end

        def dedupe(technologies)
          table = {}
          Array(technologies).each { |entry| merge_entry!(table, entry) }
          table.values.sort_by { |entry| entry['name'].downcase }
        end

        def merge_entry!(table, entry)
          name = entry['name'].to_s.strip
          return if name.empty?

          key = name.downcase
          table[key] ? merge_existing!(table[key], entry) : table[key] = new_entry(name, entry)
        end

        def merge_existing!(existing, entry)
          existing['categories'] = (Array(existing['categories']) + Array(entry['categories'])).reject(&:empty?).uniq
          return unless existing['version'].to_s.empty?
          return if entry['version'].to_s.empty?

          existing['version'] = entry['version']
        end

        def new_entry(name, entry)
          {
            'name' => name,
            'version' => entry['version'].to_s,
            'categories' => Array(entry['categories']).reject(&:empty?).uniq
          }
        end
      end
    end
  end
end
