# frozen_string_literal: true

module Nokizaru
  module Modules
    module SSLInfo
      # Rendering helpers for SSL certificate output
      module Presenter
        module_function

        def process_cert(info, result)
          scalar_pairs = info.filter_map { |key, value| [key, value] unless tree_value?(value) }
          scalar_width = scalar_pairs.map { |(key, _)| key.to_s.length }.max.to_i

          info.each do |key, value|
            render_cert_field(key, value, result, scalar_width)
          end
        end

        def render_cert_field(key, value, result, scalar_width)
          return render_scalar_field(key, value, result, scalar_width) unless tree_value?(value)

          entries = tree_entries(value)
          UI.tree_header(key)
          UI.tree_rows(entries)
          entries.each { |sub_key, sub_val| result["#{key}-#{sub_key}"] = sub_val }
        end

        def render_scalar_field(key, value, result, scalar_width)
          UI.row(:info, key, value, label_width: scalar_width)
          result[key] = value
        end

        def tree_value?(value)
          value.is_a?(Hash) || value.is_a?(Array)
        end

        def tree_entries(value)
          return value.map { |sub_key, sub_val| [sub_key, sub_val] } if value.is_a?(Hash)

          value.each_with_index.map { |sub_val, idx| [idx, sub_val] }
        end
      end
    end
  end
end
