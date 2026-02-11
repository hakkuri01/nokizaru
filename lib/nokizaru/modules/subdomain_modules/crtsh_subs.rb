# frozen_string_literal: true

require 'json'
require_relative 'base'

module Nokizaru
  module Modules
    module SubdomainModules
      module CrtSh
        module_function

        # Run this module and store normalized results in the run context
        def call(hostname, http, found)
          Base.requesting('crt.sh')

          url = "https://crt.sh/?dNSName=%25.#{hostname}&output=json"

          begin
            resp = http.get(url)
            status = Base.safe_status(resp)

            if status == 200
              output = Base.safe_body(resp)
              json_out = JSON.parse(output)

              subs = []
              json_out.each do |entry|
                name = entry['name_value']
                next unless name

                name.to_s.split("\n").each { |n| subs << n.strip }
              end

              subs.reject!(&:empty?)
              subs.uniq!
              Base.found('crt.sh', subs.length)
              found.concat(subs)
            else
              Base.print_status('crt.sh', resp)
              Log.write("[crtsh_subs] Status = #{status.inspect}, expected 200")
            end
          rescue JSON::ParserError => e
            Base.exception('crt.sh', "invalid JSON (#{e.message})")
            Log.write("[crtsh_subs] JSON parse exception = #{e}")
          rescue StandardError => e
            Base.exception('crt.sh', e)
            Log.write("[crtsh_subs] Exception = #{e}")
          end

          Log.write('[crtsh_subs] Completed')
        end
      end
    end
  end
end
