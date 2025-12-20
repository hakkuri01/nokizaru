# frozen_string_literal: true

module Nokizaru
  module Modules
    module Export
      module_function

      def call(output, data)
        if output[:format] != 'txt'
          warn("\e[31m[-] \e[36mInvalid Output Format, Valid Formats : \e[0mtxt")
          exit(1)
        end

        fname = output.fetch(:file)
        File.open(fname, 'w') do |outfile|
          txt_export(data, outfile)
        end
      end

      def txt_unpack(outfile, val)
        write_item = lambda do |item|
          if item.is_a?(Array)
            outfile.write("#{item[0]}\t#{item[1]}\t\t#{item[2]}\n")
          else
            outfile.write("#{item}\n")
          end
        end

        if val.is_a?(Array)
          val.each { |item| write_item.call(item) }
        elsif val.is_a?(Hash)
          val.each do |sub_key, sub_val|
            next if sub_key == 'exported'

            if sub_val.is_a?(Array) || sub_val.is_a?(Hash)
              txt_unpack(outfile, sub_val)
            else
              outfile.write("#{sub_key}: #{sub_val}\n")
            end
          end
        end
      end

      def txt_export(data, outfile)
        data.each do |key, val|
          key = key.to_s

          if key.start_with?('module')
            next unless val.is_a?(Hash)
            next if val['exported']

            txt_unpack(outfile, val)
            val['exported'] = true

          elsif key.start_with?('Type')
            heading = data.fetch(key)
            outfile.write("\n#{heading}\n")
            outfile.write("#{'=' * heading.length}\n\n")

          else
            outfile.write("#{key}: #{val}\n")
          end
        end
      end
    end
  end
end
