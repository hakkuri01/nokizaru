module Nokizaru::PSL
  # Validation for a Public Suffix List refresh: deterministic, no network, no
  # LLM. tools/refresh_psl.cr (maintainer-only) uses it to prove a freshly
  # fetched list is still the structured Mozilla list and that its delta against
  # the committed baseline is purely rule and comment data, so non-data cannot be
  # snuck in on an update. Walks input in one pass and looks lines up through a
  # Set, so it stays linear in the list size.
  module Validate
    ICANN_BEGIN   = "// ===BEGIN ICANN DOMAINS==="
    ICANN_END     = "// ===END ICANN DOMAINS==="
    PRIVATE_BEGIN = "// ===BEGIN PRIVATE DOMAINS==="
    PRIVATE_END   = "// ===END PRIVATE DOMAINS==="
    MARKERS       = {ICANN_BEGIN, ICANN_END, PRIVATE_BEGIN, PRIVATE_END}

    MIN_LINES = 10_000
    MAX_LINES = 40_000

    # A line that may legitimately appear in the list: blank, a `//` comment, or
    # a suffix rule. Everything else is treated as non-data.
    def self.acceptable_line?(line : String) : Bool
      stripped = line.strip
      stripped.empty? || stripped.starts_with?("//") || valid_rule_line?(stripped)
    end

    # A bare public-suffix rule: an optional `!` exception marker, then labels
    # joined by dots, each label `*` (wildcard) or letters/digits/hyphen/
    # underscore (ASCII or any Unicode letter, for IDN suffixes). No spaces,
    # slashes, quotes, or shell metacharacters, so an injected code line fails.
    def self.valid_rule_line?(line : String) : Bool
      return false if line.empty?

      body = line.starts_with?('!') ? line[1..] : line
      return false if body.empty?

      body.split('.').all? { |label| valid_label?(label) }
    end

    def self.valid_label?(label : String) : Bool
      return true if label == "*"
      return false if label.empty?

      label.each_char.all? { |c| c.letter? || c.number? || c == '-' || c == '_' }
    end

    # The list is the structured Mozilla file: four section markers in order, no
    # genuine control characters, a sane line count.
    def self.structural_ok?(text : String) : {Bool, String}
      return {false, "empty"} if text.empty?

      positions = [] of Int32
      MARKERS.each do |marker|
        index = text.index(marker)
        return {false, "missing section marker: #{marker}"} unless index
        positions << index
      end
      return {false, "section markers out of order"} unless positions == positions.sort

      return {false, "control characters present"} if text.each_char.any? { |c| control_char?(c) }

      lines = text.lines.size
      return {false, "line count #{lines} out of bounds"} unless (MIN_LINES..MAX_LINES).includes?(lines)

      {true, "ok"}
    end

    # Every line present in the new list but not the old must be acceptable data,
    # so an update can add rules and comments but never arbitrary content.
    def self.delta_is_data_only?(old_text : String, new_text : String) : {Bool, String}
      old_lines = old_text.lines.to_set
      added = new_text.lines.reject { |line| old_lines.includes?(line) }
      if bad = added.find { |line| !acceptable_line?(line) }
        return {false, "non-data line added: #{bad.inspect}"}
      end

      {true, "#{added.size} data line(s) added"}
    end

    def self.control_char?(char : Char) : Bool
      char.control? && char != '\n' && char != '\r' && char != '\t'
    end
  end
end
