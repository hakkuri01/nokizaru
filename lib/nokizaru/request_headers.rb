# frozen_string_literal: true

module Nokizaru
  # Parse and validate operator-supplied request headers for in-scope scans
  module RequestHeaders
    module_function

    HEADER_NAME_RE = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    FLAG_NAMES = ['-H', '--header'].freeze

    def parse_argv(argv)
      values = cli_values(argv)
      build_header_map(values)
    end

    def build_header_map(values)
      Array(values).each_with_object({}) do |raw, headers|
        name, value = parse_header(raw)
        headers[name] = value
      end
    end

    def parse_header(raw)
      text = raw.to_s
      raise ArgumentError, 'Custom header cannot be empty' if text.strip.empty?
      raise ArgumentError, 'Custom header cannot contain CR/LF characters' if text.match?(/[\r\n]/)

      name, value = text.split(':', 2)
      raise ArgumentError, "Invalid custom header '#{text}': expected 'Name: Value'" if value.nil?

      normalized_name = name.to_s.strip
      raise ArgumentError, 'Custom header name cannot be empty' if normalized_name.empty?

      unless normalized_name.match?(HEADER_NAME_RE)
        raise ArgumentError,
              "Invalid custom header name '#{normalized_name}'"
      end

      [normalized_name, value.lstrip]
    end

    def cli_values(argv)
      values = []
      args = Array(argv)
      index = 0

      while index < args.length
        current = args[index].to_s
        if current.start_with?('--header=', '-H=')
          values << current.split('=', 2).last
        elsif FLAG_NAMES.include?(current)
          next_value = args[index + 1]
          raise ArgumentError, "Missing value for #{current}" if next_value.nil?

          values << next_value
          index += 1
        end

        index += 1
      end

      values
    end

    def any?(headers)
      headers.is_a?(Hash) && !headers.empty?
    end

    def none?(headers)
      !any?(headers)
    end

    def summary(headers)
      count = headers.is_a?(Hash) ? headers.length : 0
      return 'none' if count.zero?

      "#{count} supplied"
    end

    def apply_to_request(request, headers)
      Array(headers).each do |name, value|
        request[name] = value
      end
      request
    end
  end
end
