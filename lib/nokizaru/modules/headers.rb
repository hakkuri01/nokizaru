# frozen_string_literal: true

require 'httpx'
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

      def call(target, ctx)
        result = { 'headers' => {} }
        puts("\n#{Y}[!] Headers :#{W}\n\n")

        begin
          rqst = HTTPX.with(timeout: { operation_timeout: 10 }).get(target, verify: false)
          rqst.headers.each do |key, val|
            puts("#{C}#{key} : #{W}#{val}")
            result['headers'][key.to_s] = val.to_s
          end
        rescue StandardError => exc
          puts("\n#{R}[-] #{C}Exception : #{W}#{exc}\n")
          result['error'] = exc.to_s
          Log.write("[headers] Exception = #{exc}")
        end

        ctx.run['modules']['headers'] = result

        Log.write('[headers] Completed')
      end
    end
  end
end
