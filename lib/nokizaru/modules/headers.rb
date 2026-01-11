# frozen_string_literal: true

require 'httpx'
require_relative '../log'
require_relative '../http_result'

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
          # Make the HTTP request
          raw_response = HTTPX.with(timeout: { operation_timeout: 10 }).get(target,
                                                                            ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE })

          # Wrap it in our HttpResult wrapper for safe handling
          http_result = HttpResult.new(raw_response)

          if http_result.success?
            # Success - display headers
            http_result.headers.each do |key, val|
              puts("#{C}#{key} : #{W}#{val}")
              result['headers'][key.to_s] = val.to_s
            end
          else
            # Error - display user-friendly message
            display_http_error(http_result, target)
            result['error'] = http_result.error_message
            result['error_type'] = http_result.error.class.name
            Log.write("[headers] #{http_result.error.class}: #{http_result.error_message}")
          end
        rescue StandardError => e
          # Catch any unexpected errors
          puts("\n#{R}[-] #{C}Unexpected error: #{W}#{e.class}")
          puts("#{R}[-] #{W}#{e.message}\n")
          result['error'] = e.to_s
          result['error_type'] = e.class.name
          Log.write("[headers] Unexpected exception = #{e.class}: #{e}")
        end

        ctx.run['modules']['headers'] = result
        Log.write('[headers] Completed')
      end

      # Display a user-friendly error message with helpful suggestions
      def display_http_error(http_result, target)
        puts("#{R}[-] #{C}Connection Failed#{W}")
        puts("#{R}[-] #{W}#{http_result.error_message}\n")

        # Show hint if available
        puts("#{Y}[!] #{C}Suggestion: #{W}#{http_result.error_hint}") if http_result.error_hint

        # For SSL errors specifically, show the HTTP alternative
        if http_result.error.is_a?(OpenSSL::SSL::SSLError) && target.start_with?('https://')
          http_url = target.sub('https://', 'http://')
          puts("#{Y}[!] #{C}Try: #{W}nokizaru --url #{http_url} [options]")
        end

        puts('')
      end
    end
  end
end
