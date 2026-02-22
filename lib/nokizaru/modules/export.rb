# frozen_string_literal: true

module Nokizaru
  module Modules
    # Nokizaru::Modules::Export implementation
    module Export
      module_function

      # Run this module and store normalized results in the run context
      def call(output, data)
        if output[:format] != 'txt'
          UI.line(:error, 'Invalid Output Format, Valid Formats : txt')
          exit(1)
        end

        fname = output.fetch(:file)
        File.open(fname, 'w') do |outfile|
          txt_export(data, outfile)
        end
      end

      # Extract plain text output from module payloads for terminal rendering
      def txt_unpack(outfile, val)
        unpack_array(outfile, val) if val.is_a?(Array)
        unpack_hash(outfile, val) if val.is_a?(Hash)
      end

      def unpack_array(outfile, values)
        values.each { |item| write_unpacked_item(outfile, item) }
      end

      def write_unpacked_item(outfile, item)
        return outfile.write("#{item}\n") unless item.is_a?(Array)

        outfile.write("#{item[0]}\t#{item[1]}\t\t#{item[2]}\n")
      end

      def unpack_hash(outfile, values)
        values.each do |sub_key, sub_val|
          next if sub_key == 'exported'

          write_unpacked_pair(outfile, sub_key, sub_val)
        end
      end

      def write_unpacked_pair(outfile, sub_key, sub_val)
        return txt_unpack(outfile, sub_val) if sub_val.is_a?(Array) || sub_val.is_a?(Hash)

        outfile.write("#{sub_key}: #{sub_val}\n")
      end

      # Render a concise text export from collected module results
      def txt_export(data, outfile)
        data.each do |key, val|
          key = key.to_s
          export_module_block?(outfile, val) and next if key.start_with?('module')
          write_heading(outfile, data.fetch(key)) and next if key.start_with?('Type')

          outfile.write("#{key}: #{val}\n")
        end
      end

      def export_module_block?(outfile, value)
        return false unless value.is_a?(Hash)
        return true if value['exported']

        txt_unpack(outfile, value)
        value['exported'] = true
        true
      end

      def write_heading(outfile, heading)
        outfile.write("\n#{heading}\n")
        outfile.write("#{'=' * heading.length}\n\n")
      end
    end
  end
end
