# frozen_string_literal: true

module Nokizaru
  module Modules
    module SubdomainModules
      # HTTP wrapper helpers for provider modules
      module BaseHTTP
        module_function

        def fetch_with_result(client, url, **options)
          raw_response = client.get(url, **options)
          HttpResult.new(raw_response)
        rescue StandardError => e
          HttpResult.new(synthetic_error_response(e))
        end

        def synthetic_error_response(error)
          response = Object.new
          response.define_singleton_method(:error) { error }
          response.instance_variable_set(:@is_error, true)
          response.define_singleton_method(:is_a?) do |klass|
            return true if klass == HTTPX::ErrorResponse

            super(klass)
          end
          response
        end
      end
    end
  end
end
