require "http/headers"

module Nokizaru
  # Parses and validates operator-supplied request headers (the -H values the CLI
  # already collected) into typed HTTP headers for in-scope scans. A malformed
  # header raises, so a bad -H stops the run rather than being sent silently.
  module RequestHeaders
    extend self

    # RFC 7230 token characters, the only ones valid in a header name.
    HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    def parse(values : Array(String)) : ::HTTP::Headers
      headers = ::HTTP::Headers.new
      values.each do |raw|
        name, value = parse_header(raw)
        headers[name] = value
      end
      headers
    end

    private def parse_header(raw : String) : Tuple(String, String)
      raise ArgumentError.new("Custom header cannot be empty") if raw.strip.empty?
      raise ArgumentError.new("Custom header cannot contain CR/LF characters") if raw.matches?(/[\r\n]/)

      name, separator, value = raw.partition(':')
      raise ArgumentError.new("Invalid custom header: expected 'Name: Value'") if separator.empty?

      name = name.strip
      raise ArgumentError.new("Custom header name cannot be empty") if name.empty?
      raise ArgumentError.new("Invalid custom header name") unless name.matches?(HEADER_NAME)

      {name, value.lstrip}
    end
  end
end
