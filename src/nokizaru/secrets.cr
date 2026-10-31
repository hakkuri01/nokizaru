require "./keystore"

module Nokizaru
  # The operator's own credentials, kept out of anything the tool prints, writes,
  # or stores. One home for the matching, because a check re-derived beside a new
  # caller is a check that drifts: supplied `-H` values are the ones a scanned
  # target can echo back, so they are matched against response data as well as
  # error text, while API keys never reach a target and only guard error text.
  module Secrets
    extend self

    MARKER = "[redacted]"

    # A short value collides with ordinary text (a cookie name, a status code
    # inside a message), and hiding every line that happens to contain it costs
    # more than it protects, so only values long enough to be a credential are
    # matched.
    MIN_TOKEN_BYTES = 8

    # The values a target could reflect: each supplied header value whole, plus
    # its cookie-style crumbs, so one cookie out of a jar still matches.
    # O(header bytes), once per use.
    def from_headers(headers : ::HTTP::Headers) : Array(String)
      tokens = [] of String
      headers.each do |_name, values|
        values.each do |value|
          append(tokens, value)
          value.split(/[;=\s]+/).each { |crumb| append(tokens, crumb) }
        end
      end
      tokens.uniq!
      tokens
    end

    # Stored API keys and NK_ environment values: never sent to a target, so
    # these guard error text only.
    def from_key_store : Array(String)
      tokens = [] of String
      KeyStore.load_keys.each_value { |value| append(tokens, value) }
      ENV.each { |name, value| append(tokens, value) if name.starts_with?("NK_") }
      tokens.uniq!
      tokens
    end

    # Replaces every occurrence with the marker. O(tokens x len) over a bounded
    # value (a header value or a capped error line) with a handful of tokens.
    def redact(text : String, tokens : Enumerable(String)) : String
      tokens.reduce(text) { |result, token| result.gsub(token, MARKER) }
    end

    def includes_any?(text : String, tokens : Enumerable(String)) : Bool
      tokens.any? { |token| text.includes?(token) }
    end

    private def append(tokens : Array(String), value : String) : Nil
      candidate = value.strip
      tokens << candidate if candidate.bytesize >= MIN_TOKEN_BYTES
    end
  end
end
