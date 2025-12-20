# frozen_string_literal: true

require 'httpx'
require_relative 'export'
require_relative '../log'

module Nokizaru
  module Modules
    module Headers
      module_function

      R = "\e[31m"  # red
      G = "\e[32m"  # green
      C = "\e[36m"  # cyan
      W = "\e[0m"   # white
      Y = "\e[33m"  # yellow

      def call(target, output, data)
        result = {}
        puts("\n#{Y}[!] Headers :#{W}\n\n")

        begin
          rqst = HTTPX.with(timeout: { operation_timeout: 10 }).get(target, verify: false)
          rqst.headers.each do |key, val|
            puts("#{C}#{key} : #{W}#{val}")
            result[key] = val if output
          end
        rescue StandardError => exc
          puts("\n#{R}[-] #{C}Exception : #{W}#{exc}\n")
          result['Exception'] = exc.to_s if output
          Log.write("[headers] Exception = #{exc}")
        end

        result['exported'] = false

        if output
          fname = File.join(output[:directory], "headers.#{output[:format]}")
          output[:file] = fname
          data['module-headers'] = result
          Export.call(output, data)
        end

        Log.write('[headers] Completed')
      end
    end
  end
end
